defmodule Portal.Queue do
  @moduledoc """
  Per-node GenServer that serializes message dispatch through its own pid
  and batches entries for a caller-owned flush callback.

  ## Why a single pid?

  Erlang only guarantees signal ordering between a specific sender pid and
  receiver pid. When two messages about the same logical event must arrive
  in send order at a remote pid — e.g. `:allow_access` followed by an
  eventual `:reject_access` if the row fails to persist, or
  `:confirm_authz_durability` if it succeeds — they must originate from a
  single sender pid. The Queue is that pid. Both `:dispatch` and `:on_flush`
  run inside the Queue process and therefore share a sender.

  ## Required options

    * `:name` — registered name for the GenServer
    * `:flush_interval` — interval in ms between automatic flushes
    * `:flush_threshold` — entry count that triggers a flush via
      `handle_continue` (out of the call path, but before any further
      message is processed by this Queue)
    * `:on_flush` — `fn entries -> non_neg_integer() end` invoked from the
      Queue process with `{attrs, metadata}` entries. The callback owns the
      domain-specific insert/recovery behavior and returns the number of rows
      inserted.

  ## Optional options

    * `:label` — short string used in log lines
    * `:callers` — pids to copy into `$callers` so the GenServer inherits
      sandbox ownership in tests.
    * `:flush_on_terminate` — when `true` (default), `terminate/2` attempts a
      best-effort flush of buffered entries and logs an info message. Tests can set
      this to `false` to drop the buffer silently on supervisor shutdown.
  """

  use GenServer
  require Logger

  @type entry :: {map(), term()}
  @type dispatch :: (-> term())
  @type on_flush :: ([entry()] -> non_neg_integer() | :ok | {:ok, non_neg_integer()})

  defmodule Config do
    @moduledoc false
    @enforce_keys [
      :flush_interval,
      :flush_threshold,
      :label,
      :on_flush,
      :flush_on_terminate
    ]
    defstruct @enforce_keys
  end

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueues `attrs` for batched insertion.

  ## Options

    * `:dispatch` — 0-arity function executed synchronously in the Queue
      process *before* the entry is buffered. Its return value becomes the
      reply to the caller, so callers can react to e.g. `{:error, :not_found}`
      from a PG delivery. Because it runs in the Queue process, any
      message it sends shares a sender pid with later `:on_flush` work —
      giving downstream receivers per-pid ordering guarantees.

      If the dispatch returns `{:error, _}`, the entry is **not** buffered.
      This avoids persisting state for a delivery that never reached the
      receiver.

    * `:metadata` — arbitrary term stored with the entry and passed to
      `:on_flush`.

  Returns the dispatch result if `:dispatch` is provided, otherwise `:ok`.
  """
  @spec enqueue(GenServer.server(), map(), keyword()) :: term()
  def enqueue(server, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    GenServer.call(server, {:enqueue, attrs, opts})
  end

  @spec flush(GenServer.server()) :: :ok
  def flush(server) do
    GenServer.call(server, :flush)
  end

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` runs on supervisor-driven shutdown — gives
    # us a best-effort window to flush whatever's buffered before the node
    # goes down. Callback exceptions are handled by `run_dispatch/1` and
    # `run_on_flush/2`.
    Process.flag(:trap_exit, true)

    callers = Keyword.get(opts, :callers, [])
    Process.put(:"$callers", callers)

    name = Keyword.fetch!(opts, :name)

    config = %Config{
      flush_interval: Keyword.fetch!(opts, :flush_interval),
      flush_threshold: Keyword.fetch!(opts, :flush_threshold),
      label: Keyword.get(opts, :label, inspect(name)),
      on_flush: Keyword.fetch!(opts, :on_flush),
      flush_on_terminate: Keyword.get(opts, :flush_on_terminate, true)
    }

    schedule_flush(config.flush_interval)
    {:ok, %{config: config, buffer: [], count: 0}}
  end

  @impl true
  def handle_call({:enqueue, attrs, opts}, _from, state) do
    case run_dispatch(Keyword.get(opts, :dispatch)) do
      {:error, _} = error ->
        {:reply, error, state}

      reply ->
        metadata = Keyword.get(opts, :metadata)

        state = %{
          state
          | buffer: [{attrs, metadata} | state.buffer],
            count: state.count + 1
        }

        if state.count >= state.config.flush_threshold do
          {:reply, reply, state, {:continue, :flush}}
        else
          {:reply, reply, state}
        end
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, do_flush(state)}
  end

  @impl true
  def handle_continue(:flush, state) do
    {:noreply, do_flush(state)}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush(state.config.flush_interval)
    {:noreply, do_flush(state)}
  end

  @impl true
  def terminate(_reason, %{buffer: buffer, config: config} = state) do
    if buffer != [] and config.flush_on_terminate do
      Logger.info(
        "Queue #{config.label} terminating with #{length(buffer)} buffered entries; " <>
          "attempting best-effort flush"
      )

      _ = do_flush(state)
    end

    :ok
  end

  defp run_dispatch(nil), do: :ok

  defp run_dispatch(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      Logger.error("Queue dispatch crashed: " <> Exception.message(error))
      {:error, :dispatch_crashed}
  catch
    kind, reason ->
      Logger.error("Queue dispatch threw #{kind}: " <> inspect(reason))
      {:error, :dispatch_crashed}
  end

  defp do_flush(%{buffer: [], count: 0} = state), do: state

  defp do_flush(%{buffer: buffer, config: config} = state) do
    now = DateTime.utc_now()

    entries =
      Enum.map(buffer, fn {attrs, metadata} ->
        {Map.put(attrs, :inserted_at, now), metadata}
      end)

    inserted = run_on_flush(entries, config)
    Logger.info("Flushed #{inserted} #{config.label} entries")

    %{state | buffer: [], count: 0}
  end

  defp run_on_flush(entries, config) do
    config.on_flush.(entries)
    |> normalize_flush_result(entries, config)
  rescue
    error ->
      Logger.error(
        "Queue #{config.label} on_flush crashed (#{length(entries)} entries): " <>
          Exception.message(error)
      )

      0
  catch
    kind, reason ->
      Logger.error(
        "Queue #{config.label} on_flush threw #{kind} (#{length(entries)} entries): " <>
          inspect(reason)
      )

      0
  end

  defp normalize_flush_result(count, _entries, _config) when is_integer(count), do: count

  defp normalize_flush_result({:ok, count}, _entries, _config) when is_integer(count), do: count

  defp normalize_flush_result(:ok, entries, _config), do: length(entries)

  defp normalize_flush_result(other, _entries, config) do
    Logger.warning(
      "Queue #{config.label} on_flush returned unexpected result: #{inspect(other)}"
    )

    0
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end
end
