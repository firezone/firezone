defmodule Portal.ClientSession.Buffer do
  use GenServer
  alias Portal.ClientSession
  alias __MODULE__.Database
  require Logger

  @flush_interval :timer.seconds(60)
  @flush_threshold 1_000

  @drop_keys [:__struct__, :__meta__, :account, :client, :client_token]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec insert(ClientSession.t(), GenServer.server()) :: :ok
  def insert(%ClientSession{} = session, server \\ __MODULE__) do
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

    {inserted, _} = Database.insert_all(entries)
    skipped = count - inserted

    if skipped > 0 do
      Logger.warning(
        "Skipped #{skipped} client sessions due to deleted associations (tokens/accounts/clients)"
      )
    end

    Logger.info("Flushed #{inserted} client sessions")

    %{buffer: [], count: 0}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  defmodule Database do
    alias Portal.ClientSession
    alias Portal.Safe
    import Ecto.Query

    def insert_all([]), do: {0, nil}

    def insert_all(entries) do
      Safe.unscoped()
      |> Safe.insert_all(ClientSession, entries)
    rescue
      error in [Postgrex.Error] ->
        case error.postgres do
          %{code: :foreign_key_violation, constraint: constraint} ->
            entries
            |> filter_existing(constraint)
            |> insert_all()

          _ ->
            reraise error, __STACKTRACE__
        end
    end

    defp filter_existing(entries, "client_sessions_account_id_fkey") do
      filter_by_existing(entries, :account_id, Portal.Account)
    end

    defp filter_existing(entries, "client_sessions_client_id_fkey") do
      filter_by_composite(entries, :client_id, Portal.Client)
    end

    defp filter_existing(entries, "client_sessions_client_token_id_fkey") do
      filter_by_composite(entries, :client_token_id, Portal.ClientToken)
    end

    defp filter_existing(_entries, _constraint), do: []

    defp filter_by_existing(entries, key, schema) do
      ids = entries |> Enum.map(& &1[key]) |> Enum.uniq()

      existing_ids =
        from(t in schema, where: t.id in ^ids, select: t.id)
        |> Safe.unscoped()
        |> Safe.all()
        |> MapSet.new()

      Enum.filter(entries, fn entry ->
        MapSet.member?(existing_ids, entry[key])
      end)
    end

    defp filter_by_composite(entries, key, schema) do
      pairs = entries |> Enum.map(fn e -> {e[:account_id], e[key]} end) |> Enum.uniq()

      conditions =
        Enum.reduce(pairs, dynamic(false), fn {account_id, id}, acc ->
          dynamic([t], ^acc or (t.account_id == ^account_id and t.id == ^id))
        end)

      existing_pairs =
        from(t in schema, where: ^conditions, select: {t.account_id, t.id})
        |> Safe.unscoped()
        |> Safe.all()
        |> MapSet.new()

      Enum.filter(entries, fn entry ->
        MapSet.member?(existing_pairs, {entry[:account_id], entry[key]})
      end)
    end
  end
end
