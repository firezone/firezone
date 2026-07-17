defmodule Portal.Azure.ManagedIdentity do
  @moduledoc """
  Fetches Microsoft Entra access tokens for the VM's user-assigned managed
  identity from the Azure Instance Metadata Service (IMDS).

  Azure Database for PostgreSQL accepts an Entra access token as the connection
  password, which is how database connections are authenticated when
  DATABASE_ENTRA_AUTH is enabled. The GenServer serializes IMDS requests and
  caches the token until shortly before it expires; tokens are only needed to
  establish new connections, so a refresh happens at most once per token
  lifetime (24 hours for managed identity tokens).
  """
  use GenServer

  @database_resource "https://ossrdbms-aad.database.windows.net"

  # Refresh this many seconds before the token expires so a connection attempt
  # never presents a token that expires mid-handshake.
  @expiry_margin_seconds 300

  # Covers the worst-case IMDS fetch (connect/receive timeouts across Req's
  # default retries)
  @call_timeout :timer.seconds(60)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, Keyword.put_new(opts, :name, __MODULE__))
  end

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

  Falls back to fetching directly when the GenServer is not running, e.g. for
  release migrations, which connect without starting the supervision tree.
  """
  def database_access_token! do
    case GenServer.whereis(__MODULE__) do
      nil ->
        %{token: token} = fetch_token!(@database_resource)
        token

      server ->
        case GenServer.call(server, :database_access_token, @call_timeout) do
          {:ok, token} -> token
          {:error, exception} -> raise exception
        end
    end
  end

  @doc """
  Fetches an uncached Entra token for an arbitrary resource audience, used by
  callers other than the database connection (e.g. a token-exchange assertion
  for workload identity federation, `api://AzureADTokenExchange`). Raises on an
  IMDS error.
  """
  def access_token!(resource) when is_binary(resource) do
    %{token: token} = fetch_token!(resource)
    token
  end

  @impl true
  def init(nil) do
    {:ok, %{token: nil, expires_at: 0}}
  end

  @impl true
  def handle_call(:database_access_token, _from, state) do
    if state.expires_at - @expiry_margin_seconds > System.system_time(:second) do
      {:reply, {:ok, state.token}, state}
    else
      try do
        state = fetch_token!(@database_resource)
        {:reply, {:ok, state.token}, state}
      rescue
        # Reply with the error instead of crashing so that an IMDS outage
        # surfaces in the calling connection process (which DBConnection
        # retries with backoff) without crash-looping this server
        exception -> {:reply, {:error, exception}, state}
      end
    end
  end

  defp fetch_token!(resource) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    req_opts = config[:req_opts] || []

    response =
      Req.get!(
        "#{config[:endpoint]}/metadata/identity/oauth2/token",
        [
          headers: [{"Metadata", "true"}],
          params: [
            "api-version": "2018-02-01",
            resource: resource,
            client_id: config[:client_id]
          ]
        ] ++ req_opts
      )

    %Req.Response{status: 200, body: %{"access_token" => token, "expires_on" => expires_on}} =
      response

    %{token: token, expires_at: expires_at(expires_on)}
  end

  defp expires_at(unix_seconds) when is_integer(unix_seconds), do: unix_seconds
  defp expires_at(unix_seconds) when is_binary(unix_seconds), do: String.to_integer(unix_seconds)
end
