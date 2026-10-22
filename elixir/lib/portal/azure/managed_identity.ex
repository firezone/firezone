defmodule Portal.Azure.ManagedIdentity do
  @moduledoc """
  Fetches Microsoft Entra access tokens for the VM's user-assigned managed
  identity from the Azure Instance Metadata Service (IMDS).

  Azure Database for PostgreSQL accepts an Entra access token as the connection
  password, which is how database connections are authenticated when
  DATABASE_ENTRA_AUTH is enabled. Other Entra integrations use managed-identity
  tokens as workload identity federation assertions. `Portal.TokenCache`
  serializes IMDS requests and caches tokens by resource until shortly before
  they expire.
  """

  @database_resource "https://ossrdbms-aad.database.windows.net"
  @token_cache Portal.Azure.TokenCache

  @doc """
  `DBConnection` `:configure` hook that replaces the connection password with a
  fresh Entra access token before every connect attempt.
  """
  def put_database_token(connection_opts) do
    Keyword.put(connection_opts, :password, database_access_token!())
  end

  @doc """
  Returns a Microsoft Entra access token for Azure Database for PostgreSQL,
  fetching a new one from IMDS if the cached one is missing or about to expire.

  Falls back to fetching directly when the token cache is not running, e.g.
  for release migrations, which connect without starting the supervision tree.
  """
  def database_access_token! do
    access_token!(@database_resource)
  end

  @doc """
  Returns a Microsoft Entra access token for an arbitrary resource audience,
  fetching a new one from IMDS if the cached one is missing or about to expire.

  This is used for token-exchange assertions for workload identity federation
  (`api://AzureADTokenExchange`) as well as database authentication. Falls back
  to fetching directly when the token cache is not running. Raises on an IMDS
  error.
  """
  def access_token!(resource) when is_binary(resource) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    token_cache = Keyword.get(config, :token_cache, @token_cache)

    case Portal.TokenCache.fetch(token_cache, resource, fn -> fetch_token(resource, config) end) do
      {:ok, token} -> token
      {:error, exception} -> raise exception
    end
  end

  defp fetch_token(resource, config) do
    req_opts =
      (config[:req_opts] || [])
      |> Keyword.put(:allow_private_ips, true)
      |> Keyword.put(:headers, [{"Metadata", "true"}])
      |> Keyword.put(:params, [
        "api-version": "2018-02-01",
        resource: resource,
        client_id: config[:client_id]
      ])

    response =
      Req.get!(
        "#{config[:endpoint]}/metadata/identity/oauth2/token",
        req_opts
      )

    %Req.Response{status: 200, body: %{"access_token" => token, "expires_on" => expires_on}} =
      response

    {:ok, %{token: token, expires_at: expires_at(expires_on)}}
  end

  defp expires_at(unix_seconds) when is_integer(unix_seconds), do: unix_seconds
  defp expires_at(unix_seconds) when is_binary(unix_seconds), do: String.to_integer(unix_seconds)
end
