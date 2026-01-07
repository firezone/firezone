defmodule Portal.GoogleCloudPlatform.Instance do
  @moduledoc """
  GenServer that caches GCP access tokens to avoid repeated metadata server calls.

  In production, this runs as a named GenServer under the GoogleCloudPlatform supervisor.
  In tests, caching is bypassed entirely - each call fetches a fresh token.
  """
  use GenServer
  alias Portal.GoogleCloudPlatform

  @mix_env Mix.env()

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(nil) do
    {:ok, %{access_token: nil, access_token_expires_at: nil}}
  end

  @doc """
  Fetches an access token, using the cache if available and not expired.

  In test mode, this bypasses caching and calls fetch_access_token directly.
  """
  def fetch_access_token do
    if @mix_env == :test do
      # In tests, bypass caching entirely
      case GoogleCloudPlatform.fetch_access_token() do
        {:ok, access_token, _expires_at} -> {:ok, access_token}
        {:error, reason} -> {:error, reason}
      end
    else
      GenServer.call(__MODULE__, :fetch_access_token)
    end
  end

  @impl true
  def handle_call(:fetch_access_token, _from, state) do
    case maybe_refresh_access_token(state) do
      {:ok, access_token, access_token_expires_at} ->
        state = %{
          state
          | access_token: access_token,
            access_token_expires_at: access_token_expires_at
        }

        {:reply, {:ok, access_token}, state}

      {:error, reason} ->
        state = %{state | access_token: nil, access_token_expires_at: nil}
        {:reply, {:error, reason}, state}
    end
  end

  defp maybe_refresh_access_token(%{access_token: nil}) do
    GoogleCloudPlatform.fetch_access_token()
  end

  defp maybe_refresh_access_token(%{access_token_expires_at: nil}) do
    GoogleCloudPlatform.fetch_access_token()
  end

  defp maybe_refresh_access_token(%{access_token: token, access_token_expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      {:ok, token, expires_at}
    else
      GoogleCloudPlatform.fetch_access_token()
    end
  end
end
