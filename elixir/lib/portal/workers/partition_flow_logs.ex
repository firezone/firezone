defmodule Portal.Workers.PartitionFlowLogs do
  @moduledoc """
  Oban worker that maintains the daily range partitions of flow_logs.

  flow_logs is partitioned by RANGE (flow_start) into one partition per UTC day.
  Each run pre-creates the partitions for the upcoming window so an insert always
  finds a child table to land in, and drops partitions whose whole day has aged
  out of the retention window. Dropping a partition is a metadata-only operation,
  so a day of logs is reclaimed without the scan-and-vacuum cost of a bulk DELETE.
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
      dates = Date.range(Date.add(today, -1), Date.add(today, lookahead_days))

      Enum.each(dates, &create_partition/1)
      Enum.count(dates)
    end

    def drop_expired_partitions(retention_days) do
      cutoff = Date.add(Date.utc_today(), -retention_days)

      expired =
        list_partition_dates()
        |> Enum.filter(&(Date.compare(&1, cutoff) == :lt))

      Enum.each(expired, &drop_partition/1)
      length(expired)
    end

    defp create_partition(date) do
      lower = bound(date)
      upper = bound(Date.add(date, 1))

      {:ok, _} =
        Safe.unscoped()
        |> Safe.query(
          "CREATE TABLE IF NOT EXISTS #{partition_name(date)} PARTITION OF flow_logs " <>
            "FOR VALUES FROM ('#{lower}') TO ('#{upper}')",
          []
        )

      :ok
    end

    defp drop_partition(date) do
      {:ok, _} =
        Safe.unscoped()
        |> Safe.query("DROP TABLE IF EXISTS #{partition_name(date)}", [])

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
