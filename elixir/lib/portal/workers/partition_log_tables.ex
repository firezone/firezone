defmodule Portal.Workers.PartitionLogTables do
  @moduledoc """
  Maintains daily UTC partitions for all four log streams, retaining the same
  121-day UTC window with 14 days of lookahead.

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

    def maintain(source, today \\ Date.utc_today()) when source in @sources do
      Safe.unscoped()
      |> Safe.checkout(fn ->
        maintain_locked(source, today)
      end)
    end

    defp maintain_locked(source, today) do
      # Preserve the established lock keys across rolling releases.
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

            maintain_partitions(table_config(source), today)
          after
            query!("SELECT set_config('lock_timeout', $1, false)", [old_timeout])

            query!(
              "SELECT pg_advisory_unlock(hashtextextended(current_schema() || '.' || $1, 0))",
              [lock_key]
            )
          end
      end
    end

    # Flow ingestion needs the previous day; the other streams also accept
    # delayed records throughout the retained window.
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
        parent: source,
        prefix: source <> "_partitioned",
        timestamp: if(source == "api_request_logs", do: "inserted_at", else: "timestamp"),
        retention_days: @retention_days,
        history_days: @retention_days
      }

    defp maintain_partitions(config, today) do
      parent = config.parent
      cutoff = Date.add(today, -config.retention_days)
      existing =
        partitions(parent, config.prefix)
        |> Enum.map(fn partition ->
          if partition.pending and Date.compare(partition.date, cutoff) != :lt do
            # Retention may have increased since a concurrent detach began.
            # Preserve the child and make it routable again before expiring others.
            query!("ALTER TABLE #{parent} DETACH PARTITION #{partition.name} FINALIZE")
            create_partition(parent, config.prefix, config.timestamp, partition.date)
            %{partition | pending: false, attached: true}
          else
            partition
          end
        end)

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
               OR (i.inhparent IS NULL AND obj_description(c.oid, 'pg_class') = $2))
        """,
        [parent, @owner]
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

    defp partition_name(parent, date), do: parent <> "_" <> Calendar.strftime(date, "%Y%m%d")
    defp bound(date), do: Date.to_iso8601(date) <> " 00:00:00+00"

    defp query!(sql, params \\ []) do
      {:ok, result} = Safe.unscoped() |> Safe.query(sql, params)
      result
    end
  end
end
