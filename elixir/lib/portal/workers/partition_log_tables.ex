defmodule Portal.Workers.PartitionLogTables do
  @moduledoc """
  Maintains daily UTC partitions for flow logs and the three log mirrors.
  Flow logs retain their existing 121-day window; mirrors retain 90 days and
  are skipped until manually activated. All streams get 14 days of lookahead.

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
    @owner "Portal.Workers.PartitionLogTables"
    @legacy_owner "Portal.Workers.PartitionLogMirrors"

    def maintain(source, today \\ Date.utc_today()) when source in @sources do
      Safe.unscoped()
      |> Safe.checkout(fn ->
        if activated?(source) do
          maintain_locked(source, today)
        else
          :not_activated
        end
      end)
    end

    defp activated?("flow_logs") do
      query!("SELECT EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = to_regclass('flow_logs'))").rows == [[true]]
    end

    defp activated?(source) do
      case query!("SELECT to_regclass('log_partition_mirrors')").rows do
        [[nil]] -> false
        _ -> query!("SELECT EXISTS (SELECT 1 FROM log_partition_mirrors WHERE source_table = $1)", [source]).rows == [[true]]
      end
    end

    defp maintain_locked(source, today) do
      config = table_config(source)
      parent = config.parent

      case query!("SELECT pg_try_advisory_lock(hashtextextended(current_schema() || '.' || $1, 0))", [parent]).rows do
        [[false]] ->
          :busy

        [[true]] ->
          [[old_timeout]] = query!("SHOW lock_timeout").rows

          try do
            query!("SELECT set_config('lock_timeout', '1s', false)")
            maintain_partitions(config, today)
          after
            query!("SELECT set_config('lock_timeout', $1, false)", [old_timeout])
            query!("SELECT pg_advisory_unlock(hashtextextended(current_schema() || '.' || $1, 0))", [parent])
          end
      end
    end

    # Preserve the established flow retention and creation window. Mirrors
    # also need historical partitions for delayed WAL and the future backfill.
    defp table_config("flow_logs"),
      do: %{parent: "flow_logs", timestamp: "flow_start", retention_days: 121, history_days: 1}

    defp table_config(source),
      do: %{
        parent: source <> "_partitioned",
        timestamp: if(source == "api_request_logs", do: "inserted_at", else: "timestamp"),
        retention_days: 90,
        history_days: 90
      }

    defp maintain_partitions(config, today) do
      parent = config.parent
      cutoff = Date.add(today, -config.retention_days)
      existing = partitions(parent)

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
      Enum.each(missing, &create_partition(parent, config.timestamp, &1))

      # Keep extending the ingestion window even when a long-running reader
      # prevents an expired partition from detaching on this run.
      Enum.each(expired, &drop_partition(parent, &1))

      %{created: length(missing), dropped: length(expired)}
    end

    defp create_partition(parent, timestamp, date) do
      name = partition_name(parent, date)
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

    defp partitions(parent) do
      query!("""
      SELECT c.relname, i.inhparent IS NOT NULL, COALESCE(i.inhdetachpending, false)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
      WHERE n.nspname = current_schema() AND c.relkind = 'r'
        AND (i.inhparent = $1::text::regclass
             OR (i.inhparent IS NULL AND obj_description(c.oid, 'pg_class') = ANY($2::text[])))
      """, [parent, [@owner, @legacy_owner]]).rows
      |> Enum.flat_map(fn [name, attached, pending] ->
        case partition_date(name, parent) do
          {:ok, date} -> [%{name: name, date: date, attached: attached, pending: pending}]
          _ -> []
        end
      end)
    end

    defp partition_date(name, parent) do
      case String.split(name, parent <> "_", parts: 2) do
        ["", <<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>] -> Date.from_iso8601("#{y}-#{m}-#{d}")
        _ -> :error
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
