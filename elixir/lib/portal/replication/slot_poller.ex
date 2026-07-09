defmodule Portal.Replication.SlotPoller do
  @moduledoc """
  Consumes a logical replication slot by polling PostgreSQL's SQL logical
  decoding interface over a regular pooled connection instead of holding a
  streaming replication-protocol connection.

  Azure Database for PostgreSQL does not support Entra token authentication
  for replication-protocol connections (the server demands SCRAM password auth
  when `replication=database` is requested), so polling is the only way to
  consume logical replication when DATABASE_ENTRA_AUTH is enabled.

  Every poll cycle runs while holding a session advisory lock on the primary
  keyed by slot and region, so exactly one process in the cluster consumes
  each slot with the database as the authority — no process-group
  coordination. Advisory locks are unavailable on standbys, so the lock
  always lives on the primary even when the slot being polled is on a
  replica. The cycle deliberately runs outside any wrapping transaction:
  consumer callbacks run arbitrary side effects whose inner transactions may
  legitimately roll back, which would poison an enclosing transaction. Within
  the cycle the poller:

    1. Captures the polled server's current WAL position, then peeks a batch
       of pgoutput messages with `pg_logical_slot_peek_binary_changes`.
    2. Decodes each message and dispatches it to the consumer callbacks.
    3. Calls `c:flush/1`, which persists or broadcasts the batch's effects.
    4. Advances the slot to the last peeked LSN, or, for an empty batch, to
       the WAL position captured in step 1 so an idle publication does not
       retain WAL. Capturing before the peek makes the idle advance safe: a
       change committed after the capture is unaffected, and one committed
       before it would have appeared in the peek.

  Advancing the slot is WAL garbage collection, not the acknowledgement: the
  slot never moves before the batch's effects are committed, so a crash
  replays the batch and delivery is at-least-once. Consumers make replay
  harmless with naturally-keyed effects (`Portal.ChangeLogs.Consumer` inserts
  are keyed by LSN with `on_conflict: :nothing`) or idempotent side effects
  (`Portal.Changes.Consumer` broadcasts).
  """

  use GenServer
  require Logger

  alias __MODULE__.Database
  alias Portal.Replication.Decoder

  @setup_retry_interval :timer.seconds(5)
  @default_poll_interval 500
  @default_batch_size 500

  @doc """
  Builds the consumer's initial state during poller setup. May query the
  database; a raise is retried together with the rest of setup.
  """
  @callback init_state(config :: map()) :: map()

  @callback on_begin(state :: map(), msg :: struct()) :: map()
  @callback on_logical_message(state :: map(), msg :: struct()) :: map()

  @callback on_write(
              state :: map(),
              lsn :: integer(),
              op :: :insert | :update | :delete,
              table :: String.t(),
              old_data :: map() | nil,
              data :: map() | nil
            ) :: map()

  @doc """
  Persists or broadcasts everything accumulated from the current batch. The
  slot is advanced past the batch only after this returns; a raise leaves the
  slot untouched so the batch is replayed.
  """
  @callback flush(state :: map()) :: map()

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    consumer = Keyword.fetch!(opts, :consumer)
    config = load_config(consumer)

    send(self(), :setup)

    {:ok,
     %{
       consumer: consumer,
       config: config,
       consumer_state: nil,
       counter: 0,
       warning_threshold_exceeded?: false,
       error_threshold_exceeded?: false
     }}
  end

  @impl true
  def handle_info(:setup, state) do
    case run_setup(state) do
      {:ok, consumer_state} ->
        Logger.info("#{inspect(state.consumer)}: replication slot poller ready",
          slot: state.config.slot_name,
          publication: state.config.publication_name
        )

        Process.send_after(self(), :status_log, state.config.status_log_interval)
        send(self(), :poll)
        {:noreply, %{state | consumer_state: consumer_state}}

      {:error, error} ->
        Logger.error("#{inspect(state.consumer)}: failed to set up replication slot, retrying",
          reason: inspect(error)
        )

        Process.send_after(self(), :setup, state.config.setup_retry_interval)
        {:noreply, state}
    end
  end

  def handle_info(:poll, state) do
    {state, drained?} = poll(state)

    delay =
      if drained? do
        state.config.poll_interval
      else
        0
      end

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  def handle_info(:status_log, state) do
    Logger.info(
      "#{inspect(state.consumer)}: Processed #{state.counter} write messages from the WAL stream"
    )

    Process.send_after(self(), :status_log, state.config.status_log_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # A cycle failure keeps the pre-cycle consumer state and leaves the slot
  # unadvanced, so the next cycle replays the same batch. The slot is advanced
  # only after the batch's effects are flushed; the WHERE guard in advance/2
  # makes racing advances harmless.
  defp poll(state) do
    {state, drained?, ack_lsn} =
      Database.with_leadership(lock_key(state.config), fn -> run_cycle(state) end) ||
        {state, true, nil}

    if ack_lsn do
      advance(state.config, ack_lsn)
    end

    {state, drained?}
  rescue
    error ->
      Logger.error("#{inspect(state.consumer)}: replication poll cycle failed",
        reason: inspect(error),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
      )

      {state, true}
  end

  defp run_cycle(state) do
    now_lsn = current_wal_lsn(state.config)
    rows = peek(state.config)

    case rows do
      [] ->
        {state, true, now_lsn}

      rows ->
        state = process_batch(state, rows)
        [last_lsn, _data] = List.last(rows)
        {state, length(rows) < state.config.batch_size, last_lsn}
    end
  end

  defp process_batch(state, rows) do
    # pgoutput re-sends Relation messages in every decoding session (one
    # session per peek call), so the relation cache is batch-local.
    {state, _relations} =
      Enum.reduce(rows, {state, %{}}, fn [lsn, data], {state, relations} ->
        data
        |> Decoder.decode_message()
        |> handle_message(lsn, state, relations)
      end)

    %{state | consumer_state: state.consumer.flush(state.consumer_state)}
  end

  defp handle_message(%Decoder.Messages.Relation{} = msg, _lsn, state, relations) do
    relation = %{namespace: msg.namespace, name: msg.name, columns: msg.columns}
    {state, Map.put(relations, msg.id, relation)}
  end

  defp handle_message(%Decoder.Messages.Begin{} = msg, _lsn, state, relations) do
    state = check_lag(state, msg.commit_timestamp)
    consumer_state = state.consumer.on_begin(state.consumer_state, msg)
    {%{state | consumer_state: consumer_state}, relations}
  end

  defp handle_message(%Decoder.Messages.LogicalMessage{} = msg, _lsn, state, relations) do
    consumer_state = state.consumer.on_logical_message(state.consumer_state, msg)
    {%{state | consumer_state: consumer_state}, relations}
  end

  defp handle_message(%mod{} = msg, lsn, state, relations)
       when mod in [Decoder.Messages.Insert, Decoder.Messages.Update, Decoder.Messages.Delete] do
    state =
      if state.error_threshold_exceeded? do
        state
      else
        {op, table, old_data, data} = transform(msg, relations)
        consumer_state = state.consumer.on_write(state.consumer_state, lsn, op, table, old_data, data)
        %{state | consumer_state: consumer_state, counter: state.counter + 1}
      end

    {state, relations}
  end

  defp handle_message(%Decoder.Messages.Unsupported{data: data}, _lsn, state, relations) do
    Logger.warning("#{inspect(state.consumer)}: Unsupported message received",
      data: inspect(data)
    )

    {state, relations}
  end

  # Commit/Origin/Truncate/Type carry nothing the consumers need.
  defp handle_message(_msg, _lsn, state, relations) do
    {state, relations}
  end

  defp transform(msg, relations) do
    {op, old_tuple_data, tuple_data} = extract_msg_data(msg)
    {:ok, relation} = Map.fetch(relations, msg.relation_id)

    {op, relation.name, zip(old_tuple_data, relation.columns), zip(tuple_data, relation.columns)}
  end

  defp extract_msg_data(%Decoder.Messages.Insert{tuple_data: data}), do: {:insert, nil, data}

  defp extract_msg_data(%Decoder.Messages.Update{old_tuple_data: old, tuple_data: data}) do
    {:update, old, data}
  end

  defp extract_msg_data(%Decoder.Messages.Delete{old_tuple_data: old}), do: {:delete, old, nil}

  defp zip(nil, _columns), do: nil

  defp zip(tuple_data, columns) do
    tuple_data
    |> Tuple.to_list()
    |> Enum.zip(columns)
    |> Map.new(&Decoder.decode_value/1)
  end

  defp check_lag(state, commit_timestamp) do
    lag_ms = DateTime.diff(DateTime.utc_now(), commit_timestamp, :millisecond)

    state
    |> check_threshold(lag_ms, :warning_threshold_exceeded?, state.config.warning_threshold,
      level: :warning,
      exceeded_message: "Processing lag exceeds warning threshold",
      recovered_message: "Processing lag is back below warning threshold"
    )
    |> check_threshold(lag_ms, :error_threshold_exceeded?, state.config.error_threshold,
      level: :error,
      exceeded_message: "Processing lag exceeds error threshold; skipping side effects!",
      recovered_message: "Processing lag is back below error threshold"
    )
  end

  defp check_threshold(state, lag_ms, flag, threshold, opts) do
    cond do
      lag_ms >= threshold and not Map.fetch!(state, flag) ->
        Logger.bare_log(
          opts[:level],
          "#{inspect(state.consumer)}: #{opts[:exceeded_message]}",
          lag_ms: lag_ms
        )

        Map.put(state, flag, true)

      lag_ms < threshold and Map.fetch!(state, flag) ->
        Logger.info("#{inspect(state.consumer)}: #{opts[:recovered_message]}", lag_ms: lag_ms)
        Map.put(state, flag, false)

      true ->
        state
    end
  end

  # Setup

  defp run_setup(state) do
    Database.ensure_publication!(state.config)
    ensure_slot!(state.config)
    {:ok, state.consumer.init_state(state.config)}
  rescue
    error -> {:error, error}
  end

  defp ensure_slot!(config) do
    %{rows: exists} =
      config.repo.query!("SELECT 1 FROM pg_replication_slots WHERE slot_name = $1", [
        config.slot_name
      ])

    if exists == [] do
      Logger.info("Creating replication slot #{config.slot_name}")

      config.repo.query!("SELECT pg_create_logical_replication_slot($1, 'pgoutput')", [
        config.slot_name
      ])
    end

    :ok
  end

  # SQL helpers. LSNs travel as bigints ('0/0'::pg_lsn arithmetic) so they can
  # be compared and stored without a pg_lsn Ecto type.

  defp peek(config) do
    %{rows: rows} =
      config.repo.query!(
        """
        SELECT (lsn - '0/0'::pg_lsn)::bigint, data
        FROM pg_logical_slot_peek_binary_changes(
          $1, NULL, $2,
          'proto_version', '1', 'publication_names', $3, 'messages', 'true'
        )
        """,
        [config.slot_name, config.batch_size, config.publication_name]
      )

    rows
  end

  # pg_last_wal_replay_lsn is non-NULL only on a standby; pg_current_wal_lsn
  # raises during recovery, which COALESCE's lazy evaluation avoids.
  defp current_wal_lsn(config) do
    %{rows: [[lsn]]} =
      config.repo.query!(
        "SELECT (COALESCE(pg_last_wal_replay_lsn(), pg_current_wal_lsn()) - '0/0'::pg_lsn)::bigint",
        []
      )

    lsn
  end

  # The WHERE clause makes both backward and no-op advances (possible under
  # :pg leader handoff races) silently do nothing: advancing backwards raises.
  defp advance(config, lsn) do
    config.repo.query!(
      """
      SELECT pg_replication_slot_advance(slot_name, '0/0'::pg_lsn + $2)
      FROM pg_replication_slots
      WHERE slot_name = $1 AND confirmed_flush_lsn < '0/0'::pg_lsn + $2
      """,
      [config.slot_name, lsn]
    )

    :ok
  end

  defp lock_key(config) do
    "#{config.slot_name}/#{config.region}"
  end

  defp load_config(consumer) do
    config = Portal.Config.fetch_env!(:portal, consumer)

    %{
      repo: Keyword.fetch!(config, :repo),
      slot_name: Keyword.fetch!(config, :replication_slot_name),
      publication_name: Keyword.fetch!(config, :publication_name),
      table_subscriptions: Keyword.fetch!(config, :table_subscriptions),
      region: Keyword.get(config, :region, ""),
      poll_interval: Keyword.get(config, :poll_interval, @default_poll_interval),
      batch_size: Keyword.get(config, :batch_size, @default_batch_size),
      warning_threshold: Keyword.fetch!(config, :warning_threshold),
      error_threshold: Keyword.fetch!(config, :error_threshold),
      status_log_interval: Keyword.get(config, :status_log_interval, :timer.minutes(1)),
      setup_retry_interval: Keyword.get(config, :setup_retry_interval, @setup_retry_interval)
    }
  end

  defmodule Database do
    require Logger

    alias Portal.Safe

    @doc """
    Runs `fun` while holding the session advisory lock for `key` on a
    checked-out primary connection, or returns nil without calling it when
    another session holds the lock.

    Deliberately not a transaction: `fun` runs consumer side effects (hooks,
    inserts) whose own inner transactions may roll back, which would poison
    any enclosing transaction and abort the cycle. The session lock is
    released in `after` on the same pinned connection; if the process dies
    mid-cycle the pool disconnects the connection and the server releases the
    lock with it.
    """
    def with_leadership(key, fun) do
      Safe.unscoped()
      |> Safe.checkout(fn ->
        {:ok, %{rows: [[locked?]]}} =
          Safe.unscoped()
          |> Safe.query("SELECT pg_try_advisory_lock(hashtext($1))", [key])

        if locked? do
          try do
            fun.()
          after
            {:ok, %{rows: [[true]]}} =
              Safe.unscoped()
              |> Safe.query("SELECT pg_advisory_unlock(hashtext($1))", [key])
          end
        else
          nil
        end
      end)
    end

    # Publications are DDL, which a read replica cannot execute, so they are
    # always managed on the primary; physical replication carries them to the
    # replicas that Portal.Changes.Consumer polls.
    def ensure_publication!(config) do
      {:ok, %{rows: exists}} =
        Safe.unscoped()
        |> Safe.query("SELECT 1 FROM pg_publication WHERE pubname = $1", [
          config.publication_name
        ])

      if exists == [] do
        tables = Enum.map_join(config.table_subscriptions, ", ", &~s(public."#{&1}"))

        Logger.info("Creating publication #{config.publication_name} with tables: #{tables}")

        {:ok, _} =
          Safe.unscoped()
          |> Safe.query("CREATE PUBLICATION #{config.publication_name} FOR TABLE #{tables}", [])
      else
        sync_publication_tables!(config)
      end

      :ok
    end

    defp sync_publication_tables!(config) do
      {:ok, %{rows: rows}} =
        Safe.unscoped()
        |> Safe.query(
          "SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = $1",
          [config.publication_name]
        )

      current = MapSet.new(rows, fn [schema, table] -> ~s(#{schema}."#{table}") end)
      desired = MapSet.new(config.table_subscriptions, &~s(public."#{&1}"))

      to_add = MapSet.difference(desired, current)
      to_remove = MapSet.difference(current, desired)

      if not Enum.empty?(to_add) do
        tables = Enum.join(to_add, ", ")
        Logger.info("Adding tables to publication #{config.publication_name}: #{tables}")

        {:ok, _} =
          Safe.unscoped()
          |> Safe.query("ALTER PUBLICATION #{config.publication_name} ADD TABLE #{tables}", [])
      end

      if not Enum.empty?(to_remove) do
        tables = Enum.join(to_remove, ", ")
        Logger.info("Removing tables from publication #{config.publication_name}: #{tables}")

        {:ok, _} =
          Safe.unscoped()
          |> Safe.query("ALTER PUBLICATION #{config.publication_name} DROP TABLE #{tables}", [])
      end

      :ok
    end
  end
end
