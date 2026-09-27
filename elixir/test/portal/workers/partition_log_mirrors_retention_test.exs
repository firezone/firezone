defmodule Portal.Workers.PartitionLogMirrorsRetentionTest do
  # DETACH CONCURRENTLY cannot run in the SQL sandbox transaction. These tests
  # use committed DDL on empty, expired partitions and clean up explicitly.
  use ExUnit.Case, async: true

  import Portal.LogPartitionMirrorFixtures

  alias Portal.Repo
  alias Portal.Workers.PartitionLogMirrors.Database

  @parent "session_logs_partitioned"
  @owner "Portal.Workers.PartitionLogMirrors"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    :ok
  end

  test "drops expired partitions concurrently and retains the boundary day" do
    with_mirror_schema("session_logs", fn _schema ->
      name = expired_partition()

      try do
        assert Database.maintain("session_logs") == %{created: 0, dropped: 1}
        assert Repo.query!("SELECT to_regclass($1)", [name]).rows == [[nil]]

        boundary = @parent <> "_" <> Calendar.strftime(Date.add(Date.utc_today(), -90), "%Y%m%d")
        assert [[oid]] = Repo.query!("SELECT to_regclass($1)", [boundary]).rows
        assert is_integer(oid)
      after
        Repo.query!("DROP TABLE IF EXISTS #{name}")
      end
    end)
  end

  test "recovers a detach that committed but whose drop never ran" do
    with_mirror_schema("session_logs", fn _schema ->
      name = expired_partition()

      try do
        Repo.query!("ALTER TABLE #{@parent} DETACH PARTITION #{name} CONCURRENTLY")
        assert Database.maintain("session_logs") == %{created: 0, dropped: 1}
        assert Repo.query!("SELECT to_regclass($1)", [name]).rows == [[nil]]
      after
        Repo.query!("DROP TABLE IF EXISTS #{name}")
      end
    end)
  end

  test "finalizes an interrupted concurrent detach before detaching another partition" do
    with_mirror_schema("session_logs", fn schema ->
      name = expired_partition()
      other = expired_partition(-92)
      reader = connection(schema)

      try do
        Postgrex.query!(reader, "BEGIN", [])
        Postgrex.query!(reader, "SELECT * FROM #{@parent} LIMIT 1", [])
        Repo.query!("SET statement_timeout = '200ms'")

        assert_raise Postgrex.Error, fn ->
          Repo.query!("ALTER TABLE #{@parent} DETACH PARTITION #{name} CONCURRENTLY")
        end

        Repo.query!("SET statement_timeout = 0")

        assert Repo.query!("SELECT inhdetachpending FROM pg_inherits WHERE inhrelid = $1::text::regclass", [name]).rows == [[true]]
        Postgrex.query!(reader, "ROLLBACK", [])

        assert Database.maintain("session_logs") == %{created: 0, dropped: 2}
        assert Repo.query!("SELECT to_regclass($1)", [name]).rows == [[nil]]
      after
        GenServer.stop(reader)
        Repo.query!("SET statement_timeout = 0")
        Repo.query!("DROP TABLE IF EXISTS #{name}")
        Repo.query!("DROP TABLE IF EXISTS #{other}")
      end
    end)
  end

  test "another maintainer holds the advisory lock" do
    with_mirror_schema("session_logs", fn schema ->
      connection = connection(schema)

      try do
        Postgrex.query!(connection, "SELECT pg_advisory_lock(hashtextextended(current_schema() || '.' || $1, 0))", [@parent])
        assert Database.maintain("session_logs") == :busy
      after
        GenServer.stop(connection)
      end
    end)
  end

  defp expired_partition(offset \\ -91) do
    date = Date.add(Date.utc_today(), offset)
    name = @parent <> "_" <> Calendar.strftime(date, "%Y%m%d")
    lower = Date.to_iso8601(date) <> " 00:00:00+00"
    upper = Date.to_iso8601(Date.add(date, 1)) <> " 00:00:00+00"

    Repo.query!("CREATE TABLE #{name} PARTITION OF #{@parent} FOR VALUES FROM ('#{lower}') TO ('#{upper}')")
    Repo.query!("COMMENT ON TABLE #{name} IS '#{@owner}'")
    name
  end

  defp connection(schema) do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database, :socket_dir])
    {:ok, connection} = Postgrex.start_link(opts)
    Postgrex.query!(connection, "SELECT set_config('search_path', $1, false)", [schema])
    connection
  end
end
