defmodule Portal.Sophos.APIClient do
  @moduledoc """
  Client for the Sophos Central Endpoint API v1.

  Credentials are exchanged for a one-hour bearer token at Sophos ID. `whoami`
  then names the tenant the credentials belong to and the regional host that
  serves its data, and every tenant call carries that tenant in `X-Tenant-ID`.
  Partner and organization credentials have no regional host of their own, so
  only tenant credentials are accepted.

  Endpoints are paged by key: each page names the next with `pages.nextKey`
  and the last page has none. `view=full` is asked for explicitly, as the
  default view leaves out an undocumented set of fields.
  """

  @token_url "https://id.sophos.com/api/v2/oauth2/token"
  @whoami_url "https://api.central.sophos.com/whoami/v1"
  @endpoints_path "/endpoint/v1/endpoints"
  @page_size 100
  @data_region_url ~r/^https:\/\/api-[a-z0-9]+\.central\.sophos\.com$/

  @doc "What a regional API host looks like. The bearer token is sent there, so nothing else is accepted."
  def data_region_url_format, do: @data_region_url

  @doc "The Endpoint API operation used for endpoint inventory."
  def endpoints_path, do: @endpoints_path

  @doc "Exchanges API credentials for a bearer token."
  def get_access_token(client_id, client_secret) do
    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => client_id || "",
        "client_secret" => client_secret || "",
        "scope" => "token"
      })

    case Req.post(
           @token_url,
           [headers: [{"Content-Type", "application/x-www-form-urlencoded"}], body: body] ++
             req_opts()
         ) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}}
      when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %Req.Response{} = response} ->
        {:error, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The tenant the token belongs to and the regional host serving its data."
  def whoami(access_token) do
    case Req.get(@whoami_url, [headers: auth_headers(access_token)] ++ req_opts()) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse_whoami(body)
      {:ok, %Req.Response{} = response} -> {:error, response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Proves that the credentials belong to a tenant and can read its endpoints.
  Returns the tenant id and regional host to store on the provider.
  """
  def verify(client_id, client_secret) do
    with {:ok, token} <- get_access_token(client_id, client_secret),
         {:ok, tenant} <- whoami(token),
         {:ok, _endpoints, _next_key} <- get_page(token, tenant, nil, 1) do
      {:ok, tenant}
    end
  end

  @doc "Streams every page of endpoints in the tenant."
  def stream_endpoints(access_token, %{tenant_id: _, data_region_url: _} = tenant) do
    Stream.resource(
      fn -> :first end,
      fn
        nil ->
          {:halt, nil}

        key ->
          case get_page(access_token, tenant, key, @page_size) do
            {:ok, endpoints, next_key} -> {[endpoints], next_key}
            {:error, reason} -> {[{:error, reason}], nil}
          end
      end,
      fn _state -> :ok end
    )
  end

  defp parse_whoami(%{"id" => id, "idType" => "tenant", "apiHosts" => %{"dataRegion" => url}})
       when is_binary(id) and id != "" and is_binary(url) do
    url = String.trim_trailing(url, "/")

    if Regex.match?(@data_region_url, url) do
      {:ok, %{tenant_id: id, data_region_url: url}}
    else
      {:error, {:invalid_response, "apiHosts.dataRegion is not a Sophos host", url}}
    end
  end

  defp parse_whoami(%{"idType" => id_type}) when is_binary(id_type),
    do: {:error, :unsupported_credentials}

  defp parse_whoami(body), do: {:error, {:invalid_response, "unexpected whoami response", body}}

  defp get_page(access_token, tenant, key, page_size) do
    params = [pageSize: page_size, view: "full"]
    params = if is_binary(key), do: Keyword.put(params, :pageFromKey, key), else: params

    case Req.get(
           tenant.data_region_url <> @endpoints_path,
           [
             headers: [{"X-Tenant-ID", tenant.tenant_id} | auth_headers(access_token)],
             params: params
           ] ++ req_opts()
         ) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse_page(body)
      {:ok, %Req.Response{} = response} -> {:error, response}
      {:error, reason} -> {:error, reason}
    end
  end

  # A run deletes endpoints it stops seeing, so a response shape we do not
  # recognise has to fail rather than read as an empty tenant.
  defp parse_page(%{"items" => items, "pages" => pages} = body)
       when is_list(items) and is_map(pages) do
    case Map.get(pages, "nextKey") do
      key when is_binary(key) and key != "" -> {:ok, items, key}
      key when key in [nil, ""] -> {:ok, items, nil}
      _invalid -> {:error, {:invalid_response, "pages.nextKey is invalid", body}}
    end
  end

  defp parse_page(body),
    do: {:error, {:invalid_response, "expected items list and pages object", body}}

  defp auth_headers(access_token) do
    [{"Authorization", "Bearer #{access_token}"}, {"Accept", "application/json"}]
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)[:req_opts] || []
  end
end
