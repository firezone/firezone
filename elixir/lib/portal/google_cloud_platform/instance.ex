defmodule Portal.GoogleCloudPlatform.Instance do
  use GenServer
  alias Portal.GoogleCloudPlatform

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(nil) do
    {:ok, %{access_token: nil, access_token_expires_at: nil}}
  end

  def fetch_access_token do
    callers = Process.get(:"$callers") || []
    last_caller = List.first(callers) || self()
    metadata = Logger.metadata()
    GenServer.call(__MODULE__, {:fetch_access_token, last_caller, metadata})
  end

  @impl true
  def handle_call({:fetch_access_token, last_caller, metadata}, _from, state) do
    # Propagate logger metadata
    Logger.metadata(metadata)

    # Allows GenServer to find the caller process for pdict config overrides
    Process.put(:last_caller_pid, last_caller)

    case maybe_refresh_access_token(state) do
      {:ok, access_token, access_token_expires_at} ->
        state = %{
          state
          | access_token: access_token,
            access_token_expires_at: access_token_expires_at
        }

        {:reply, {:ok, access_token}, state}

      {:error, reason} ->
        state = %{
          state
          | access_token: nil,
            access_token_expires_at: nil
        }

        {:reply, {:error, reason}, state}
    end
  end

  defp maybe_refresh_access_token(state) do
    cond do
      is_nil(state.access_token) ->
        GoogleCloudPlatform.fetch_access_token()

      is_nil(state.access_token_expires_at) ->
        GoogleCloudPlatform.fetch_access_token()

      DateTime.diff(state.access_token_expires_at, DateTime.utc_now()) > 0 ->
        {:ok, state.access_token, state.access_token_expires_at}

      true ->
        GoogleCloudPlatform.fetch_access_token()
    end
  end
end
