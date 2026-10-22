defmodule Portal.Req.SSRFProtection do
  @moduledoc """
  A Req plugin for requests to user-configured HTTP endpoints.

  The plugin resolves the request host immediately before the adapter runs,
  rejects private and special-use addresses, and pins the connection to one of
  the checked addresses. The original hostname is retained for TLS certificate
  verification, SNI, and the HTTP `Host` header.

  Keeping this at the adapter boundary means retries and redirects are checked
  independently instead of relying on validation performed when a database
  record was created.

  Firezone attaches the plugin to every Req request through Req's global default
  options. Private addresses are denied by default. A client that intentionally
  calls an internal service must opt out explicitly:

      Req.get!(url, allow_private_ips: true)

  Deployments that need the portal to reach private networks for all requests can
  disable the plugin with `HTTP_CLIENT_SSRF_PROTECTION_ENABLED=false`.
  """

  @default_pool_max_idle_time :timer.minutes(1)
  @original_adapter_key :portal_ssrf_protection_original_adapter
  @resolver_key :portal_ssrf_protection_resolver

  defmodule UnsafeURLError do
    defexception [:host, :reason]

    @impl true
    def message(%__MODULE__{host: host, reason: :non_public_address}) do
      "request to #{inspect(host)} was blocked because it resolves to a private or reserved IP address"
    end

    def message(%__MODULE__{host: host, reason: :nxdomain}) do
      "request to #{inspect(host)} failed because the host could not be resolved"
    end

    def message(%__MODULE__{host: host, reason: :invalid_url}) do
      "request was blocked because #{inspect(host)} is not a valid HTTP host"
    end
  end

  @type resolver :: (:inet.hostname(), :inet | :inet6 ->
                       {:ok, [:inet.ip_address()]} | {:error, term()})

  @doc false
  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = request), do: attach(request, [])

  @doc false
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = request, options) do
    request = Req.Request.register_options(request, [:allow_private_ips])

    request =
      case Keyword.fetch(options, :resolver) do
        {:ok, resolver} -> Req.Request.put_private(request, @resolver_key, resolver)
        :error -> request
      end

    if request.adapter == __MODULE__ do
      request
    else
      request
      |> Req.Request.put_private(@original_adapter_key, request.adapter)
      |> Map.put(:adapter, __MODULE__)
    end
  end

  @doc false
  @spec resolve_public_address(String.t(), resolver()) ::
          {:ok, :inet.ip_address()} | {:error, :non_public_address | :nxdomain}
  def resolve_public_address(host, resolver \\ &:inet.getaddrs/2)

  def resolve_public_address(host, resolver) when is_binary(host) and host != "" do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        validate_addresses([ip])

      {:error, _reason} ->
        charlist
        |> resolve_addresses(resolver)
        |> validate_addresses()
    end
  end

  def resolve_public_address(_host, _resolver), do: {:error, :nxdomain}

  defp resolve_addresses(host, resolver) do
    [:inet, :inet6]
    |> Enum.flat_map(&resolve_addresses(host, &1, resolver))
    |> Enum.uniq()
  end

  defp resolve_addresses(host, family, resolver) do
    case resolver.(host, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  defp validate_addresses([]), do: {:error, :nxdomain}

  defp validate_addresses(addresses) do
    if Enum.any?(addresses, &Portal.Changeset.private_ip?/1) do
      {:error, :non_public_address}
    else
      # Prefer IPv4, matching Req's default connection behavior. Because every
      # returned address was checked, selecting any member is safe.
      address = Enum.find(addresses, &(tuple_size(&1) == 4)) || List.first(addresses)
      {:ok, address}
    end
  end

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    if request.options[:allow_private_ips] do
      run_original_adapter(request)
    else
      resolver = Req.Request.get_private(request, @resolver_key) || (&:inet.getaddrs/2)
      run_protected(request, resolver)
    end
  end

  defp run_protected(
         %Req.Request{url: %URI{scheme: scheme, host: host}} = request,
         resolver
       )
       when scheme in ["http", "https"] and is_binary(host) and host != "" do
    case resolve_public_address(host, resolver) do
      {:ok, address} ->
        request
        |> pin_request(address)
        |> run_original_adapter(request)

      {:error, reason} ->
        {request, %UnsafeURLError{host: host, reason: reason}}
    end
  end

  defp run_protected(%Req.Request{} = request, _resolver) do
    {request, %UnsafeURLError{host: request.url.host, reason: :invalid_url}}
  end

  defp pin_request(%Req.Request{} = request, address) do
    original_host = request.url.host
    address_string = address |> :inet.ntoa() |> to_string()
    connect_options = Keyword.put(request.options[:connect_options] || [], :hostname, original_host)
    inet6? = tuple_size(address) == 8

    request
    |> Req.Request.put_header("host", authority(request.url))
    |> put_in([Access.key(:url), Access.key(:host)], address_string)
    |> put_in([Access.key(:options), :connect_options], connect_options)
    |> put_in([Access.key(:options), :inet6], inet6?)
  end

  defp run_original_adapter(%Req.Request{} = request) do
    original_adapter = Req.Request.get_private(request, @original_adapter_key)
    call_adapter(original_adapter, request)
  end

  defp run_original_adapter(%Req.Request{} = pinned_request, %Req.Request{} = original_request) do
    original_adapter = Req.Request.get_private(original_request, @original_adapter_key)

    pinned_request =
      if original_adapter == Req.Finch do
        use_pinned_finch_pool(pinned_request, original_request.url.host)
      else
        pinned_request
      end

    case call_adapter(original_adapter, pinned_request) do
      {%Req.Request{}, response_or_error} -> {original_request, response_or_error}
    end
  end

  defp call_adapter(adapter, request) when is_atom(adapter), do: adapter.run(request)
  defp call_adapter(adapter, request) when is_function(adapter, 1), do: adapter.(request)

  # Req creates a named Finch instance for each distinct set of connection
  # options. Since the TLS hostname is user-controlled here, doing that would
  # create atoms dynamically. A tagged pool on Req's existing Finch instance
  # pins the checked IP without creating atoms.
  defp use_pinned_finch_pool(%Req.Request{} = request, original_host) do
    pool_options =
      request.options
      |> Req.Finch.pool_options()
      |> Keyword.update(:conn_opts, [hostname: original_host], fn conn_opts ->
        Keyword.put(conn_opts, :hostname, original_host)
      end)
      |> Keyword.put_new(:pool_max_idle_time, @default_pool_max_idle_time)

    tag = {__MODULE__, original_host, request.options[:connect_options] || []}

    pool = %Finch.Pool{
      scheme: String.to_existing_atom(request.url.scheme),
      host: request.url.host,
      port: request.url.port || URI.default_port(request.url.scheme),
      tag: tag
    }

    :ok = Finch.start_pool(Req.Finch, pool, pool_options)

    options =
      request.options
      |> Map.delete(:connect_options)
      |> Map.put(:finch, name: Req.Finch, pool_tag: tag)

    %{request | options: options}
  end

  defp authority(%URI{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    if port && port != URI.default_port(scheme) do
      "#{host}:#{port}"
    else
      host
    end
  end
end
