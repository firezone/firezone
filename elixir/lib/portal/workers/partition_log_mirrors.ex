defmodule Portal.Workers.PartitionLogMirrors do
  @moduledoc """
  Maintains daily UTC partitions for the session, API request and change-log
  mirrors. This worker does not switch reads or rename tables. Activation is a
  manual migration; before activation it is a no-op, including during rollout.

  Retains the full boundary day at 90 days and creates 14 days ahead. As with
  flow logs, ATTACH and DETACH CONCURRENTLY allow ingestion to continue. A
  session advisory lock serializes maintenance, and interrupted detach/drop
  operations are resumed on the next run.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias __MODULE__.Database

  @impl Oban.Worker
  def perform(_job) do
    for source <- ~w[session_logs api_request_logs change_logs] do
      result = Database.maintain(source)
      Logger.info("Maintained log mirror partitions", source: source, result: inspect(result))
    end

    :ok
  end

  defmodule Database do
    alias Portal.Safe

    @sources ~w[session_logs api_request_logs change_logs]
    @owner "Portal.Workers.PartitionLogMirrors"

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

    defp activated?(source) do
      case query!("SELECT to_regclass('log_partition_mirrors')").rows do
        [[nil]] -> false
        _ -> query!("SELECT EXISTS (SELECT 1 FROM log_partition_mirrors WHERE source_table = $1)", [source]).rows == [[true]]
      end
    end

    defp maintain_locked(source, today) do
      parent = source <> "_partitioned"

      case query!("SELECT pg_try_advisory_lock(hashtextextended(current_schema() || '.' || $1, 0))", [parent]).rows do
        [[false]] ->
          :busy

        [[true]] ->
          [[old_timeout]] = query!("SHOW lock_timeout").rows

          try do
            query!("SELECT set_config('lock_timeout', '1s', false)")
            maintain_partitions(parent, source, today)
          after
            query!("SELECT set_config('lock_timeout', $1, false)", [old_timeout])
            query!("SELECT pg_advisory_unlock(hashtextextended(current_schema() || '.' || $1, 0))", [parent])
          end
      end
    end

    defp maintain_partitions(parent, source, today) do
      cutoff = Date.add(today, -90)
      existing = partitions(parent)

      # A failed DETACH CONCURRENTLY can leave inhdetachpending set. Finish it
      # before attempting another detach on the same parent. A failed DROP is
      # recoverable because detached tables retain our ownership comment.
      expired =
        existing
        |> Enum.filter(&(Date.compare(&1.date, cutoff) == :lt))
        |> Enum.sort_by(& &1.pending, :desc)
      Enum.each(expired, &drop_partition(parent, &1))

      attached =
        existing
        |> Enum.filter(& &1.attached)
        |> MapSet.new(& &1.date)

      wanted = Date.range(cutoff, Date.add(today, 14))
      missing = Enum.reject(wanted, &MapSet.member?(attached, &1))
      timestamp = if source == "api_request_logs", do: "inserted_at", else: "timestamp"
      Enum.each(missing, &create_partition(parent, timestamp, &1))

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
        AND obj_description(c.oid, 'pg_class') = $2
        AND (i.inhparent = $1::text::regclass OR i.inhparent IS NULL)
      """, [parent, @owner]).rows
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
