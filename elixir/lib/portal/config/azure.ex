defmodule Portal.Config.Azure do
  @moduledoc """
  Reads portal settings from Azure App Configuration with the VM's managed
  identity.

  Settings are read from `config/runtime.exs`, before any application starts,
  so requests go through `:httpc` instead of Req. Key Vault references are
  resolved to their secret values. Only keys without a label are read.

  Each key's `mode` tag says whether a running portal may apply a change to it
  (`live`) or needs a restart (`boot`). Keys without the tag are `boot`. Keys
  with an empty value are left out, so they fall back like a missing key.

  Endpoints are tried in order, so a replica can serve when the primary cannot.
  """

  @app_configuration_resource "https://azconfig.io"
  @key_vault_resource "https://vault.azure.net"
  @app_configuration_api_version "2023-11-01"
  @key_vault_api_version "7.4"
  @key_vault_reference_content_type "application/vnd.microsoft.appconfig.keyvaultref+json"
  @imds_token_url "http://169.254.169.254/metadata/identity/oauth2/token"

  @type http_get ::
          (url :: String.t(), headers :: [{String.t(), String.t()}] ->
             {:ok, status :: pos_integer(), body :: binary()} | {:error, term()})

  @type setting :: %{value: String.t(), mode: :live | :boot}

  @doc """
  Returns every setting in the store with its mode, with Key Vault references
  replaced by their secret values. Raises if no endpoint can be read.
  """
  @spec fetch_settings!([String.t()], String.t() | nil, http_get()) ::
          %{String.t() => setting()}
  def fetch_settings!([_ | _] = endpoints, client_id, http_get \\ &http_get/2) do
    store_token = access_token!(@app_configuration_resource, client_id, http_get)

    items =
      endpoints
      |> list_first_readable!(store_token, http_get, [])
      |> Enum.reject(&(&1["value"] in [nil, ""]))

    vault_token =
      if Enum.any?(items, &key_vault_reference?/1),
        do: access_token!(@key_vault_resource, client_id, http_get)

    Map.new(items, fn item ->
      {item["key"], %{value: resolve_value!(item, vault_token, http_get), mode: mode(item)}}
    end)
  end

  defp list_first_readable!([], _token, _http_get, errors) do
    raise "no App Configuration endpoint could be read: " <> Enum.join(Enum.reverse(errors), "; ")
  end

  defp list_first_readable!([endpoint | rest], token, http_get, errors) do
    endpoint = String.trim_trailing(endpoint, "/")
    url = "#{endpoint}/kv?label=%00&api-version=#{@app_configuration_api_version}"

    try do
      list_key_values!(url, endpoint, token, http_get, [])
    rescue
      # Our own errors never include response bodies; other exceptions might.
      exception in RuntimeError ->
        list_first_readable!(rest, token, http_get, [exception.message | errors])

      exception ->
        list_first_readable!(rest, token, http_get, [inspect(exception.__struct__) | errors])
    end
  end

  @doc """
  Writes settings to `path` with mode 0600, replacing the file atomically.
  """
  @spec write_cache!(Path.t(), %{String.t() => setting()}) :: :ok
  def write_cache!(path, settings) do
    json =
      JSON.encode!(Map.new(settings, fn {key, %{value: value, mode: mode}} ->
        {key, %{"value" => value, "mode" => Atom.to_string(mode)}}
      end))

    tmp_path = path <> ".tmp"
    File.write!(tmp_path, "")
    File.chmod!(tmp_path, 0o600)
    File.write!(tmp_path, json)
    File.rename!(tmp_path, path)
  end

  @doc """
  Reads settings written by `write_cache!/2`.
  """
  @spec read_cache(Path.t()) :: {:ok, %{String.t() => setting()}} | :error
  def read_cache(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{} = cached} <- JSON.decode(json) do
      {:ok,
       Map.new(cached, fn {key, %{"value" => value, "mode" => mode}} ->
         {key, %{value: value, mode: if(mode == "live", do: :live, else: :boot)}}
       end)}
    else
      _other -> :error
    end
  end

  defp list_key_values!(url, endpoint, token, http_get, acc) do
    %{"items" => items} = body = get_json!(url, token, http_get)

    case body["@nextLink"] do
      nil -> acc ++ items
      next_link -> list_key_values!(endpoint <> next_link, endpoint, token, http_get, acc ++ items)
    end
  end

  defp resolve_value!(item, vault_token, http_get) do
    if key_vault_reference?(item) do
      %{"uri" => uri} = JSON.decode!(item["value"])
      secret_uri = validate_secret_uri!(item["key"], uri)
      %{"value" => value} = get_json!(secret_uri, vault_token, http_get)
      value
    else
      item["value"]
    end
  end

  defp mode(%{"tags" => %{"mode" => "live"}}), do: :live
  defp mode(_item), do: :boot

  defp key_vault_reference?(%{"content_type" => content_type}) when is_binary(content_type),
    do: String.starts_with?(content_type, @key_vault_reference_content_type)

  defp key_vault_reference?(_item), do: false

  # A Key Vault token is only ever sent to a Key Vault host.
  defp validate_secret_uri!(key, uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, path: "/secrets/" <> _} = parsed
      when is_binary(host) ->
        if String.ends_with?(host, ".vault.azure.net") do
          URI.to_string(%{parsed | query: "api-version=#{@key_vault_api_version}"})
        else
          raise "#{key} references a secret outside Azure Key Vault"
        end

      _other ->
        raise "#{key} has an invalid Key Vault reference"
    end
  end

  defp access_token!(resource, client_id, http_get) do
    query =
      URI.encode_query(
        Enum.reject(
          [{"api-version", "2018-02-01"}, {"resource", resource}, {"client_id", client_id}],
          fn {_key, value} -> is_nil(value) end
        )
      )

    case http_get.("#{@imds_token_url}?#{query}", [{"Metadata", "true"}]) do
      {:ok, 200, body} ->
        %{"access_token" => token} = JSON.decode!(body)
        token

      {:ok, status, _body} ->
        raise "managed identity token request for #{resource} failed with HTTP #{status}"

      {:error, reason} ->
        raise "managed identity token request for #{resource} failed: #{inspect(reason)}"
    end
  end

  defp get_json!(url, token, http_get) do
    %URI{host: host} = URI.parse(url)

    case http_get.(url, [{"Authorization", "Bearer #{token}"}]) do
      {:ok, 200, body} ->
        JSON.decode!(body)

      {:ok, status, _body} ->
        raise "request to #{host} failed with HTTP #{status}"

      {:error, reason} ->
        raise "request to #{host} failed: #{inspect(reason)}"
    end
  end

  defp http_get(url, headers) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])

    request = {String.to_charlist(url), Enum.map(headers, &to_charlist_header/1)}

    http_options = [
      timeout: 10_000,
      connect_timeout: 5_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_charlist_header({name, value}),
    do: {String.to_charlist(name), String.to_charlist(value)}
end
