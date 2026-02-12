defmodule Portal.GatewaySession.Buffer do
  use GenServer
  alias Portal.GatewaySession
  alias __MODULE__.Database
  require Logger

  @flush_interval :timer.seconds(60)
  @flush_threshold 1_000

  @drop_keys [:__struct__, :__meta__, :account, :gateway, :gateway_token]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec insert(GatewaySession.t(), GenServer.server()) :: :ok
  def insert(%GatewaySession{} = session, server \\ __MODULE__) do
    GenServer.cast(server, {:insert, session})
  end

  @doc """
  Synchronously flushes the buffer.
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush)
  end

  @impl true
  def init(opts) do
    callers = Keyword.get(opts, :callers, [])
    Process.put(:"$callers", callers)
    schedule_flush()
    {:ok, %{buffer: [], count: 0}}
  end

  @impl true
  def handle_cast({:insert, session}, state) do
    state = %{state | buffer: [session | state.buffer], count: state.count + 1}

    if state.count >= @flush_threshold do
      {:noreply, flush_buffer(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, flush_buffer(state)}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush()
    {:noreply, flush_buffer(state)}
  end

  defp flush_buffer(%{buffer: [], count: 0} = state), do: state

  defp flush_buffer(%{buffer: buffer, count: count}) do
    now = DateTime.utc_now()

    entries =
      Enum.map(buffer, fn session ->
        session
        |> Map.from_struct()
        |> Map.drop(@drop_keys)
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:inserted_at, now)
      end)

    Database.insert_all(entries)

    Logger.info("Flushed #{count} gateway sessions")

    %{buffer: [], count: 0}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  defmodule Database do
    alias Portal.GatewaySession
    alias Portal.Safe

    def insert_all(entries) do
      Safe.unscoped()
      |> Safe.insert_all(GatewaySession, entries)
    end
  end
end
