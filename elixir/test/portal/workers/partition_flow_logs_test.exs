defmodule Portal.Workers.PartitionFlowLogsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.PartitionFlowLogs

  @lookahead_days 14
  @retention_days 121

  # Creating or dropping a partition takes an ACCESS EXCLUSIVE lock on the parent
  # flow_logs. In production each statement auto-commits, so the lock is released
  # between operations; here the whole worker runs inside the test's sandbox
  # transaction. Acquiring the parent lock up front means the worker never holds a
  # partition lock while waiting for the parent, which would otherwise deadlock
  # with the concurrent flow_logs writes of other async tests. It just serializes
  # those writes behind this (short) test instead.
  setup do
    Repo.query!("LOCK TABLE flow_logs IN ACCESS EXCLUSIVE MODE")
    :ok
  end

  describe "perform/1" do
    test "pre-creates the partition at the far edge of the lookahead window" do
      edge = Date.add(Date.utc_today(), @lookahead_days)
      drop_partition(edge)
      refute partition_exists?(edge)

      assert :ok = perform_job(PartitionFlowLogs, %{})

      assert partition_exists?(edge)
    end

    test "creates today's partition" do
      today = Date.utc_today()
      drop_partition(today)

      assert :ok = perform_job(PartitionFlowLogs, %{})

      assert partition_exists?(today)
    end

    test "drops a partition whose day has aged past the retention window" do
      expired = Date.add(Date.utc_today(), -(@retention_days + 1))
      create_partition(expired)
      assert partition_exists?(expired)

      assert :ok = perform_job(PartitionFlowLogs, %{})

      refute partition_exists?(expired)
    end

    test "keeps a partition still inside the retention window" do
      retained = Date.add(Date.utc_today(), -(@retention_days - 1))
      create_partition(retained)

      assert :ok = perform_job(PartitionFlowLogs, %{})

      assert partition_exists?(retained)
    end
  end

  defp partition_name(date), do: "flow_logs_" <> Calendar.strftime(date, "%Y%m%d")

  defp partition_exists?(date) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = $1)", [
        partition_name(date)
      ])

    exists
  end

  defp create_partition(date) do
    lower = Date.to_iso8601(date) <> " 00:00:00+00"
    upper = Date.to_iso8601(Date.add(date, 1)) <> " 00:00:00+00"

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS #{partition_name(date)} PARTITION OF flow_logs " <>
        "FOR VALUES FROM ('#{lower}') TO ('#{upper}')"
    )
  end

  defp drop_partition(date) do
    Repo.query!("DROP TABLE IF EXISTS #{partition_name(date)}")
  end
end
