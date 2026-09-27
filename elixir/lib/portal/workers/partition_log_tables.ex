defmodule Portal.Workers.PartitionLogTables do
  @moduledoc """
  Maintains daily UTC partitions for all four log streams, following each
  mirror through its rename to the canonical table. All streams retain the
  same 121-day UTC window and get 14 days of lookahead. Mirrors are skipped
  until manually activated.

  ATTACH and DETACH CONCURRENTLY allow ingestion to continue. Session advisory
  locks serialize maintenance; interrupted detach/drop operations are resumed
  on the next run. This worker does not backfill, switch reads, or rename tables.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias __MODULE__.Database

  @impl Oban.Worker
  def perform(_job) do
    for source <- ~w[flow_logs session_logs api_request_logs change_logs] do
      result = Database.maintain(source)
      Logger.info("Maintained log table partitions", source: source, result: inspect(result))
    end

    :ok
  end

  defmodule Database do
    alias Portal.Safe

    @sources ~w[flow_logs session_logs api_request_logs change_logs]
    @retention_days 121
    @owner "Portal.Workers.PartitionLogTables"
    @legacy_owner "Portal.Workers.PartitionLogMirrors"

    def maintain(source, today \\ Date.utc_today()) when source in @sources do
      Safe.unscoped()
      |> Safe.checkout(fn ->
        maintain_locked(source, today)
      end)
    end

    defp activated?("flow_logs") do
      query!(
        "SELECT EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = to_regclass('flow_logs'))"
      ).rows == [[true]]
    end

    defp activated?(source) do
      partitioned?(source) or mirror_activated?(source)
    end

    defp mirror_activated?(source) do
      case query!("SELECT to_regclass('log_partition_mirrors')").rows do
        [[nil]] ->
          false

        _ ->
          query!("SELECT EXISTS (SELECT 1 FROM log_partition_mirrors WHERE source_table = $1)", [
            source
          ]).rows == [[true]]
      end
    end

    defp maintain_locked(source, today) do
      # Keep the same lock key through cutover, and resolve names only AFTER
      # acquiring it. Cutover uses this key before renaming either parent.
      lock_key = if source == "flow_logs", do: source, else: source <> "_partitioned"

      case query!(
             "SELECT pg_try_advisory_lock(hashtextextended(current_schema() || '.' || $1, 0))",
             [lock_key]
           ).rows do
        [[false]] ->
          :busy

        [[true]] ->
          [[old_timeout]] = query!("SHOW lock_timeout").rows

          try do
            query!("SELECT set_config('lock_timeout', '1s', false)")

            if activated?(source),
              do: maintain_partitions(table_config(source), today),
              else: :not_activated
          after
            query!("SELECT set_config('lock_timeout', $1, false)", [old_timeout])

            query!(
              "SELECT pg_advisory_unlock(hashtextextended(current_schema() || '.' || $1, 0))",
              [lock_key]
            )
          end
      end
    end

    # Preserve the established flow retention and creation window. Mirrors
    # also need historical partitions for delayed WAL and backfill.
    defp table_config("flow_logs"),
      do: %{
        parent: "flow_logs",
        prefix: "flow_logs",
        timestamp: "flow_start",
        retention_days: @retention_days,
        history_days: 1
      }

    defp table_config(source),
      do: %{
        parent: if(partitioned?(source), do: source, else: source <> "_partitioned"),
        prefix: source <> "_partitioned",
        timestamp: if(source == "api_request_logs", do: "inserted_at", else: "timestamp"),
        retention_days: @retention_days,
        history_days: @retention_days
      }

    defp maintain_partitions(config, today) do
      parent = config.parent
      cutoff = Date.add(today, -config.retention_days)
      existing = partitions(parent, config.prefix)

      # A failed DETACH CONCURRENTLY can leave inhdetachpending set. Finish it
      # before attempting another detach on the same parent. A failed DROP is
      # recoverable because detached tables retain our ownership comment.
      expired =
        existing
        |> Enum.filter(&(Date.compare(&1.date, cutoff) == :lt))
        |> Enum.sort_by(& &1.pending, :desc)

      attached =
        existing
        |> Enum.filter(& &1.attached)
        |> MapSet.new(& &1.date)

      wanted = Date.range(Date.add(today, -config.history_days), Date.add(today, 14))
      missing = Enum.reject(wanted, &MapSet.member?(attached, &1))
      Enum.each(missing, &create_partition(parent, config.prefix, config.timestamp, &1))

      # Keep extending the ingestion window even when a long-running reader
      # prevents an expired partition from detaching on this run.
      Enum.each(expired, &drop_partition(parent, &1))

      %{created: length(missing), dropped: length(expired)}
    end

    defp create_partition(parent, prefix, timestamp, date) do
      name = partition_name(prefix, date)
      lower = bound(date)
      upper = bound(Date.add(date, 1))

      # Standalone creation avoids ACCESS EXCLUSIVE on the active parent. The
      # bound CHECK also avoids scanning the child while ATTACH holds its lock.
      query!("""
      CREATE TABLE IF NOT EXISTS #{name} (
        LIKE #{parent} INCLUDING DEFAULTS INCLUDING CONSTRAINTS,
        CONSTRAINT #{name}_bounds CHECK (#{timestamp} >= TIMESTAMPTZ '#{lower}'
                                       AND #{timestamp} < TIMESTAMPTZ '#{upper}')
      )
      """)

      query!("COMMENT ON TABLE #{name} IS '#{@owner}'")

      query!("""
      ALTER TABLE #{parent} ATTACH PARTITION #{name}
        FOR VALUES FROM ('#{lower}') TO ('#{upper}')
      """)
    end

    defp drop_partition(parent, partition) do
      # Existing flow partitions predate ownership comments. Mark them before
      # detaching so an interrupted DROP is recoverable too.
      query!("COMMENT ON TABLE #{partition.name} IS '#{@owner}'")

      cond do
        partition.pending ->
          query!("ALTER TABLE #{parent} DETACH PARTITION #{partition.name} FINALIZE")

        partition.attached ->
          query!("ALTER TABLE #{parent} DETACH PARTITION #{partition.name} CONCURRENTLY")

        true ->
          :ok
      end

      query!("DROP TABLE IF EXISTS #{partition.name}")
    end

    defp partitions(parent, prefix) do
      query!(
        """
        SELECT c.relname, i.inhparent IS NOT NULL, COALESCE(i.inhdetachpending, false)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
        WHERE n.nspname = current_schema() AND c.relkind = 'r'
          AND (i.inhparent = $1::text::regclass
               OR (i.inhparent IS NULL AND obj_description(c.oid, 'pg_class') = ANY($2::text[])))
        """,
        [parent, [@owner, @legacy_owner]]
      ).rows
      |> Enum.flat_map(fn [name, attached, pending] ->
        case partition_date(name, prefix) do
          {:ok, date} -> [%{name: name, date: date, attached: attached, pending: pending}]
          _ -> []
        end
      end)
    end

    defp partition_date(name, parent) do
      case String.split(name, parent <> "_", parts: 2) do
        ["", <<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>] ->
          Date.from_iso8601("#{y}-#{m}-#{d}")

        _ ->
          :error
      end
    end

    defp partitioned?(source) do
      query!(
        "SELECT EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = to_regclass($1))",
        [source]
      ).rows == [[true]]
    end

    defp partition_name(parent, date), do: parent <> "_" <> Calendar.strftime(date, "%Y%m%d")
    defp bound(date), do: Date.to_iso8601(date) <> " 00:00:00+00"

    defp query!(sql, params \\ []) do
      {:ok, result} = Safe.unscoped() |> Safe.query(sql, params)
      result
    end
  end
end
