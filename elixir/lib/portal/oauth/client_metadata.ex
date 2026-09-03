defmodule Portal.OAuth.ClientMetadata do
  @moduledoc """
  Resolves an OAuth client id into the metadata document it names.

  MCP clients identify themselves with an HTTPS URL that serves a JSON document
  describing them, so there is no registration step and no client secret. The
  document is fetched on demand, checked, and cached.

  The URL comes from whoever started the authorization request, so the fetch is
  treated as hostile: `Portal.Req.SSRFProtection` is already attached to every
  request and refuses private and reserved addresses, and the caps here bound
  how much time and memory one lookup can cost.
  """

  alias Portal.OAuthClient
  alias __MODULE__.Database

  require Logger

  @loopback_hosts ~w[localhost 127.0.0.1 ::1]

  # Navigating to any of these runs in the page that navigates, so none of them
  # is ever a place to send an authorization code.
  @script_schemes ~w[javascript vbscript data blob file filesystem about view-source]

  @max_icon_bytes 64 * 1024
  # Raster only. An SVG can carry script, and while that does not run from an
  # img tag it is not worth storing and serving back.
  @icon_types ~w[image/png image/jpeg image/gif image/webp image/x-icon image/vnd.microsoft.icon]

  @receive_timeout :timer.seconds(5)
  @max_body_bytes 64 * 1024
  @min_cache :timer.minutes(5)
  @default_cache :timer.hours(1)
  @max_cache :timer.hours(24)

  @doc """
  Returns the client for `client_id`, fetching and caching the document when
  the cached copy is missing or stale.
  """
  def fetch(client_id) do
    with :ok <- validate_client_id(client_id) do
      case Database.fetch_fresh_client(client_id) do
        {:ok, client} -> {:ok, client}
        :error -> fetch_and_cache(client_id)
      end
    end
  end

  @doc """
  Checks a redirect URI from an authorization request against the document.

  Compared exactly, with no prefix or wildcard matching, because a loose match
  here is what turns an open redirect into a stolen authorization code.
  """
  def validate_redirect_uri(%OAuthClient{} = client, redirect_uri) do
    if redirect_uri in client.redirect_uris or loopback_match?(client, redirect_uri) do
      :ok
    else
      {:error, :invalid_redirect_uri}
    end
  end

  # RFC 8252 section 7.3: a native app takes an ephemeral loopback port from the
  # operating system at request time, so the port cannot be registered ahead of
  # time and must not be compared. Everything else still matches exactly, and
  # only these literal loopback hosts qualify - a name that merely resolves to
  # one does not.
  defp loopback_match?(%OAuthClient{redirect_uris: registered}, redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: "http", host: host, fragment: nil} = uri when host in @loopback_hosts ->
        Enum.any?(registered, &(without_port(URI.parse(&1)) == without_port(uri)))

      _other ->
        false
    end
  end

  defp without_port(%URI{} = uri), do: %{uri | port: nil, authority: nil}

  defp validate_client_id(client_id) when is_binary(client_id) do
    case URI.parse(client_id) do
      %URI{scheme: "https", host: host, path: path}
      when is_binary(host) and is_binary(path) and path != "" and path != "/" ->
        :ok

      _other ->
        {:error, :invalid_client_id}
    end
  end

  defp validate_client_id(_client_id), do: {:error, :invalid_client_id}

  defp fetch_and_cache(client_id) do
    with {:ok, response} <- get(client_id),
         {:ok, document} <- decode(response.body),
         :ok <- validate_document(document, client_id) do
      upsert(document, client_id, cache_until(response), fetch_icon(document), origin(client_id))
    else
      {:error, reason} = error ->
        Logger.info("OAuth client metadata fetch failed",
          client_id: client_id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp get(client_id) do
    Req.get(
      client_id,
      [
        headers: [{"accept", "application/json"}],
        receive_timeout: @receive_timeout,
        max_retries: 0,
        redirect: false,
        into: &collect(&1, &2, @max_body_bytes)
      ] ++ req_opts()
    )
    |> case do
      {:ok, %Req.Response{status: 200} = response} -> {:ok, response}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Halting mid-body keeps an oversized or endless document from being read into
  # memory, which a plain byte check after the fact would not.
  defp collect({:data, data}, {request, response}, max_bytes) do
    body = (response.body || "") <> data

    if byte_size(body) > max_bytes do
      {:halt, {request, %{response | body: :too_large}}}
    else
      {:cont, {request, %{response | body: body}}}
    end
  end

  defp decode(:too_large), do: {:error, :document_too_large}

  # Req decodes a JSON body itself, even when the response was streamed into a
  # collector, so the document usually arrives already parsed.
  defp decode(document) when is_map(document), do: {:ok, document}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _other -> {:error, :invalid_document}
    end
  end

  defp decode(_body), do: {:error, :invalid_document}

  # The document has to name itself. Without this check any URL could serve a
  # document claiming to be some other, more trusted client.
  defp validate_document(document, client_id) do
    with %{"client_id" => ^client_id, "client_name" => name, "redirect_uris" => uris}
         when is_binary(name) and is_list(uris) <- document,
         true <- uris != [] and Enum.all?(uris, &usable_redirect_uri?/1),
         true <- Enum.all?(~w[client_uri logo_uri], &optional_string?(document[&1])) do
      :ok
    else
      _other -> {:error, :invalid_document}
    end
  end

  # Checked when the document is stored rather than when a request arrives, so
  # a URI that survives to `validate_redirect_uri/2` is already known to be one
  # a browser can be sent to. https, the http loopback of RFC 8252 section 7.3,
  # and the private-use schemes of section 7.1 that native apps register - but
  # never a scheme that runs script in the page doing the navigating.
  defp usable_redirect_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      %URI{scheme: "http", host: host} when host in @loopback_hosts -> true
      %URI{scheme: scheme} when is_binary(scheme) -> scheme not in @script_schemes
      _other -> false
    end
  end

  defp usable_redirect_uri?(_uri), do: false

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  # Best effort and never fatal: a client without a usable icon still connects,
  # it just shows its initial instead. Tried in the order a client would expect
  # it to be honoured.
  defp fetch_icon(document) do
    [document["logo_uri"], favicon_uri(document["client_uri"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(&get_icon/1)
  end

  defp favicon_uri(nil), do: nil

  defp favicon_uri(client_uri) do
    case URI.parse(client_uri) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        URI.to_string(%URI{scheme: "https", host: host, path: "/favicon.ico"})

      _other ->
        nil
    end
  end

  defp get_icon(uri) do
    with %URI{scheme: "https"} <- URI.parse(uri),
         {:ok, %Req.Response{status: 200, body: body} = response} when is_binary(body) <-
           Req.get(
             uri,
             [
               receive_timeout: @receive_timeout,
               max_retries: 0,
               redirect: true,
               into: &collect(&1, &2, @max_icon_bytes)
             ] ++ req_opts()
           ),
         type when is_binary(type) <- content_type(response),
         true <- type in @icon_types,
         true <- byte_size(body) in 1..@max_icon_bytes do
      {body, type}
    else
      _other -> nil
    end
  end

  defp content_type(response) do
    response
    |> Req.Response.get_header("content-type")
    |> List.first()
    |> case do
      nil -> nil
      value -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    end
  end

  defp upsert(document, client_id, metadata_expires_at, icon, origin) do
    {ips, region, city} = origin

    %OAuthClient{}
    |> Ecto.Changeset.cast(
      %{
        client_id: client_id,
        client_name: document["client_name"],
        client_uri: document["client_uri"],
        logo_uri: document["logo_uri"],
        logo_data: icon && elem(icon, 0),
        logo_content_type: icon && elem(icon, 1),
        redirect_uris: document["redirect_uris"],
        resolved_ips: ips,
        resolved_ip_location_region: region,
        resolved_ip_location_city: city,
        metadata_expires_at: metadata_expires_at
      },
      ~w[client_id client_name client_uri logo_uri logo_data logo_content_type
         redirect_uris resolved_ips resolved_ip_location_region
         resolved_ip_location_city metadata_expires_at]a
    )
    |> Database.upsert_client()
  end

  # Where the document was actually served from. Recorded for the consent
  # screen: the name and logo are whatever the client wrote about itself, so
  # the address it answered on is the part worth showing next to them. Best
  # effort, and never fatal - a client whose host will not resolve here has
  # already served its document.
  defp origin(client_id) do
    with %URI{host: host} when is_binary(host) <- URI.parse(client_id),
         ips when ips != [] <- resolve(host) do
      {region, city} = locate(hd(ips))
      {ips, region, city}
    else
      _other -> {[], nil, nil}
    end
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    Enum.flat_map([:inet, :inet6], fn family ->
      case :inet.getaddrs(charlist, family) do
        {:ok, addresses} -> addresses
        {:error, _reason} -> []
      end
    end)
  end

  defp locate(ip) do
    {region, city, _coordinates} = Portal.Geo.locate(ip, [])
    {region, city}
  end

  defp req_opts, do: Portal.Config.fetch_env!(:portal, __MODULE__)[:req_opts] || []

  defp cache_until(%Req.Response{} = response) do
    milliseconds =
      response
      |> Req.Response.get_header("cache-control")
      |> List.first()
      |> max_age()
      |> case do
        nil -> @default_cache
        seconds -> seconds |> :timer.seconds() |> min(@max_cache) |> max(@min_cache)
      end

    DateTime.add(DateTime.utc_now(), milliseconds, :millisecond)
  end

  defp max_age(nil), do: nil

  defp max_age(cache_control) do
    case Regex.run(~r/max-age=(\d+)/i, cache_control) do
      [_match, seconds] -> String.to_integer(seconds)
      nil -> nil
    end
  end

  defmodule Database do
    @moduledoc false
    import Ecto.Query

    alias Portal.OAuthClient
    alias Portal.Safe

    def fetch_fresh_client(client_id) do
      now = DateTime.utc_now()

      from(clients in OAuthClient,
        where: clients.client_id == ^client_id,
        where: clients.metadata_expires_at > ^now
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> :error
        client -> {:ok, client}
      end
    end

    # `returning: true` matters: the id is generated client side, so without it
    # a conflicting insert would hand back the id it just made up rather than
    # the id of the row that grants already point at.
    def upsert_client(changeset) do
      Safe.insert(Portal.Repo, changeset,
        on_conflict:
          {:replace,
           ~w[client_name client_uri logo_uri logo_data logo_content_type redirect_uris
              resolved_ips resolved_ip_location_region resolved_ip_location_city
              metadata_expires_at updated_at]a},
        conflict_target: [:client_id],
        returning: true
      )
    end
  end
end
