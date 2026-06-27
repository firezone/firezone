defmodule Portal.Workers.PartitionFlowLogs do
  @moduledoc """
  Oban worker that maintains the daily range partitions of flow_logs.

  flow_logs is partitioned by RANGE (flow_start) into one partition per UTC day.
  Each run pre-creates the partitions for the upcoming window so an insert always
  finds a child table to land in, and drops partitions whose whole day has aged
  out of the retention window. Dropping a partition is a metadata-only operation,
  so a day of logs is reclaimed without the scan-and-vacuum cost of a bulk DELETE.

  Both add (ATTACH) and remove (DETACH CONCURRENTLY) take only a SHARE UPDATE
  EXCLUSIVE lock on flow_logs, so ingestion (and the accounts FK cascade) keep
  running while partitions are maintained. The drop path cannot run inside a
  transaction, so it is exercised on staging rather than the sandboxed test suite.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  # Daily partitions are pre-created this many days ahead so a flow whose start
  # is mildly skewed into the future still finds a partition. Beyond this window
  # an insert raises rather than silently landing in a catch-all, surfacing gross
  # clock skew instead of hiding it.
  @lookahead_days 14

  # Partitions whose whole day is older than this are dropped. Kept above the
  # 90-day product retention so a flow is never pruned early at the day boundary.
  @retention_days 121

  @impl Oban.Worker
  def perform(_job) do
    created = Database.create_upcoming_partitions(@lookahead_days)
    dropped = Database.drop_expired_partitions(@retention_days)

    Logger.info("Maintained flow_logs partitions", created: created, dropped: dropped)

    :ok
  end

  defmodule Database do
    alias Portal.Safe

    def create_upcoming_partitions(lookahead_days) do
      today = Date.utc_today()

      # Start one day back so a flow that closed just before midnight but is
      # reported by a slightly-behind clock still has its partition.
      wanted = Enum.to_list(Date.range(Date.add(today, -1), Date.add(today, lookahead_days)))
      existing = MapSet.new(list_partition_dates())
      missing = Enum.reject(wanted, &MapSet.member?(existing, &1))

      Enum.each(missing, &create_partition/1)
      length(missing)
    end

    def drop_expired_partitions(retention_days) do
      cutoff = Date.add(Date.utc_today(), -retention_days)

      expired =
        list_partition_dates()
        |> Enum.filter(&(Date.compare(&1, cutoff) == :lt))

      Enum.each(expired, &drop_partition/1)
      length(expired)
    end

    # Add the partition by creating it standalone and ATTACHing it, not via
    # CREATE TABLE ... PARTITION OF. ATTACH takes a SHARE UPDATE EXCLUSIVE lock on
    # flow_logs, which does not conflict with inserts, so ingestion keeps writing
    # while the partition is added; CREATE ... PARTITION OF would take ACCESS
    # EXCLUSIVE and block all writes. The child only needs matching columns: ATTACH
    # propagates the parent's primary key, CHECK constraints, and indexes onto the
    # new partition. LIKE ... INCLUDING DEFAULTS copies columns and defaults only;
    # INCLUDING ALL would also copy the primary key, and ATTACH would then fail with
    # "multiple primary keys for table not allowed".
    defp create_partition(date) do
      name = partition_name(date)
      lower = bound(date)
      upper = bound(Date.add(date, 1))

      {:ok, _} =
        Safe.unscoped()
        |> Safe.query("CREATE TABLE IF NOT EXISTS #{name} (LIKE flow_logs INCLUDING DEFAULTS)", [])

      {:ok, _} =
        Safe.unscoped()
        |> Safe.query(
          "ALTER TABLE flow_logs ATTACH PARTITION #{name} " <>
            "FOR VALUES FROM ('#{lower}') TO ('#{upper}')",
          []
        )

      :ok
    end

    # Detach the partition concurrently, then drop the now-standalone table.
    # DETACH ... CONCURRENTLY takes only SHARE UPDATE EXCLUSIVE on flow_logs, so
    # ingestion keeps writing and the accounts FK cascade is not blocked; a plain
    # DROP would take ACCESS EXCLUSIVE. It cannot run inside a transaction, so this
    # path is exercised on staging rather than in the sandboxed test suite.
    defp drop_partition(date) do
      name = partition_name(date)

      {:ok, _} =
        Safe.unscoped()
        |> Safe.query("ALTER TABLE flow_logs DETACH PARTITION #{name} CONCURRENTLY", [])

      {:ok, _} =
        Safe.unscoped()
        |> Safe.query("DROP TABLE IF EXISTS #{name}", [])

      :ok
    end

    defp list_partition_dates do
      {:ok, %{rows: rows}} =
        Safe.unscoped()
        |> Safe.query(
          "SELECT c.relname FROM pg_inherits i " <>
            "JOIN pg_class c ON c.oid = i.inhrelid " <>
            "WHERE i.inhparent = 'flow_logs'::regclass",
          []
        )

      rows
      |> Enum.map(fn [name] -> parse_partition_date(name) end)
      |> Enum.reject(&is_nil/1)
    end

    # Names are derived only from dates we compute (digits only), never from
    # request input, so interpolating them into the DDL above is injection-safe.
    defp partition_name(date), do: "flow_logs_" <> Calendar.strftime(date, "%Y%m%d")

    defp bound(date), do: Date.to_iso8601(date) <> " 00:00:00+00"

    defp parse_partition_date(
           "flow_logs_" <> <<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>
         ) do
      case Date.from_iso8601("#{y}-#{m}-#{d}") do
        {:ok, date} -> date
        _ -> nil
      end
    end

    defp parse_partition_date(_), do: nil
  end
end
