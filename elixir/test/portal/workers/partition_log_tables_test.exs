defmodule Portal.Workers.PartitionLogTablesTest do
  use Portal.DataCase, async: true

  import Portal.LogPartitionFixtures

  alias Portal.Workers.PartitionLogTables.Database

  test "flow maintenance recognizes existing unmarked partitions and preserves its creation window" do
    with_partition_schema("flow_logs", fn _schema ->
      historical = "flow_logs_" <> Calendar.strftime(Date.add(Date.utc_today(), -10), "%Y%m%d")
      upcoming = "flow_logs_" <> Calendar.strftime(Date.add(Date.utc_today(), 14), "%Y%m%d")
      Repo.query!("DROP TABLE #{historical}")
      Repo.query!("DROP TABLE #{upcoming}")

      assert Database.maintain("flow_logs") == %{created: 1, dropped: 0}
      assert Repo.query!("SELECT to_regclass($1)", [historical]).rows == [[nil]]
      assert Database.maintain("flow_logs") == %{created: 0, dropped: 0}
    end)
  end

  test "maintenance is idempotent after seeding" do
    with_partition_schema("session_logs", fn _schema ->
      assert Database.maintain("session_logs") == %{created: 0, dropped: 0}
      assert Database.maintain("session_logs") == %{created: 0, dropped: 0}
    end)
  end

  test "recreates a missing future partition with the parent constraints and indexes" do
    with_partition_schema("api_request_logs", fn _schema ->
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
