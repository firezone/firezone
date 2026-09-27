defmodule Portal.Workers.PartitionLogTablesTest do
  use Portal.DataCase, async: true

  import Portal.LogPartitionMirrorFixtures

  alias Portal.Workers.PartitionLogTables.Database

  test "the new app and previously queued flow jobs work before mirror activation" do
    with_mirror_schema("flow_logs", fn _schema ->
      assert Database.maintain("flow_logs") == %{created: 0, dropped: 0}
      assert Portal.Workers.PartitionLogTables.perform(%Oban.Job{}) == :ok
      assert Portal.Workers.PartitionFlowLogs.perform(%Oban.Job{}) == :ok
      assert Database.maintain("session_logs") == :not_activated
    end)
  end

  test "flow maintenance recognizes existing unmarked partitions and preserves its creation window" do
    with_mirror_schema("flow_logs", fn _schema ->
      historical = "flow_logs_" <> Calendar.strftime(Date.add(Date.utc_today(), -10), "%Y%m%d")
      upcoming = "flow_logs_" <> Calendar.strftime(Date.add(Date.utc_today(), 14), "%Y%m%d")
      Repo.query!("DROP TABLE #{historical}")
      Repo.query!("DROP TABLE #{upcoming}")

      assert Database.maintain("flow_logs") == %{created: 1, dropped: 0}
      assert Repo.query!("SELECT to_regclass($1)", [historical]).rows == [[nil]]
      assert Database.maintain("flow_logs") == %{created: 0, dropped: 0}
    end)
  end

  test "skips a deployment before the manual migration" do
    with_mirror_schema("session_logs", fn _schema ->
      Repo.query!("ALTER TABLE log_partition_mirrors RENAME TO log_partition_mirrors_not_installed")
      assert Database.maintain("session_logs") == :not_activated
    end)
  end

  test "skips mirrors not yet activated during the manual migration" do
    with_mirror_schema("session_logs", fn _schema ->
      Repo.query!("DELETE FROM log_partition_mirrors WHERE source_table = 'session_logs'")
      assert Database.maintain("session_logs") == :not_activated
    end)
  end

  test "maintenance is idempotent after seeding" do
    with_mirror_schema("session_logs", fn _schema ->
      assert Database.maintain("session_logs") == %{created: 0, dropped: 0}
      assert Database.maintain("session_logs") == %{created: 0, dropped: 0}
    end)
  end

  test "recreates a missing future partition with the parent constraints and indexes" do
    with_mirror_schema("api_request_logs", fn _schema ->
      date = Date.add(Date.utc_today(), 14)
      name = "api_request_logs_partitioned_" <> Calendar.strftime(date, "%Y%m%d")
      Repo.query!("DROP TABLE #{name}")

      assert Database.maintain("api_request_logs") == %{created: 1, dropped: 0}
      assert Database.maintain("api_request_logs") == %{created: 0, dropped: 0}

      assert %{rows: [[true]]} = Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = $1::text::regclass AND contype = 'p')", [name])
      assert %{rows: [[true]]} = Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = $1::text::regclass AND contype = 'f')", [name])
    end)
  end
end
