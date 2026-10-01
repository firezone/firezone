defmodule Portal.LogTableMigrationTest do
  use ExUnit.Case, async: true

  alias Portal.{APIRequestLog, ChangeLog, Repo, SessionLog}

  alias Portal.Repo.Migrations.{
    CreateLogPartitionMirrors,
    AlignLogPartitionRetention,
    PrepareLogTableCutover,
    BackfillLogTables,
    LogTableMigration,
    CutOverLogTables,
    RemoveLogPartitionRolloutState,
    RequirePartitionedLogTables
  }

  alias Portal.Types.LogId

  for {module, file} <- [
        {CreateLogPartitionMirrors, "20260927000000_create_log_partition_mirrors.exs"},
        {AlignLogPartitionRetention, "20260927010000_align_log_partition_retention.exs"},
        {PrepareLogTableCutover, "20260928000000_prepare_log_table_cutover.exs"},
        {BackfillLogTables, "20260928010000_backfill_log_tables.exs"},
        {CutOverLogTables, "20260928020000_cut_over_log_tables.exs"},
        {RemoveLogPartitionRolloutState, "20260929010000_remove_log_partition_rollout_state.exs"}
      ] do
    unless Code.ensure_loaded?(module),
      do: Code.require_file("priv/repo/manual_migrations/" <> file)
  end

  unless Code.ensure_loaded?(RequirePartitionedLogTables),
    do: Code.require_file("priv/repo/migrations/20260929000000_require_partitioned_log_tables.exs")

  @sources ~w[session_logs api_request_logs change_logs]

  setup ctx do
    schema = "log_cutover_#{System.unique_integer([:positive])}"

    repo =
      if ctx[:isolated_database] do
        Portal.IsolatedLogDatabaseFixtures.start_isolated_repo(@sources,
          parameters: [search_path: schema]
        )
      else
        {:ok, repo} =
          Repo.start_link(
            name: nil,
            pool: DBConnection.ConnectionPool,
            pool_size: 3,
            parameters: [search_path: schema]
          )

        repo
      end

    previous = Repo.put_dynamic_repo(repo)
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("CREATE TABLE accounts (id uuid PRIMARY KEY)")
    Repo.query!("CREATE TABLE oban_jobs (id bigserial PRIMARY KEY, worker text, state text)")

    for source <- @sources do
      Repo.query!(
        "CREATE TABLE #{source} (LIKE public.#{source} INCLUDING DEFAULTS INCLUDING CONSTRAINTS, PRIMARY KEY (account_id, log_id))"
      )

      if source == "change_logs", do: Repo.query!("CREATE UNIQUE INDEX ON change_logs (lsn)")

      Repo.query!(
        "ALTER TABLE #{source} ADD CONSTRAINT #{source}_account_id_fkey FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE"
      )

      Repo.query!("CREATE SEQUENCE #{source}_seq_seq OWNED BY #{source}.seq")
      Repo.query!("ALTER TABLE #{source} ALTER seq SET DEFAULT nextval('#{source}_seq_seq')")
    end

    account_id = Ecto.UUID.generate()
    Repo.query!("INSERT INTO accounts VALUES ($1::text::uuid)", [account_id])
    # Historical rows exist before the mirror trigger is installed.
    historical =
      for source <- @sources, into: %{} do
        field = if source == "api_request_logs", do: :inserted_at, else: :timestamp

        {source,
         insert(source, account_id, nil, %{field => DateTime.add(DateTime.utc_now(), -100, :day)})}
      end

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_927_000_000, CreateLogPartitionMirrors,
               prefix: schema,
               log: false
             )

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_927_010_000, AlignLogPartitionRetention,
               prefix: schema,
               log: false
             )

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_928_000_000, PrepareLogTableCutover,
               prefix: schema,
               log: false
             )

    on_exit(fn ->
      Repo.put_dynamic_repo(repo)
      Repo.query!("DROP SCHEMA #{schema} CASCADE")
      Repo.put_dynamic_repo(previous)
      if Process.alive?(repo), do: GenServer.stop(repo)
    end)

    # Keep the pool alive until on_exit (start_link's owner otherwise exits).
    Process.unlink(repo)
    {:ok, account_id: account_id, historical: historical, schema: schema}
  end

  test "retention upgrade admits the full 121-day boundary and reruns preserve activation", ctx do
    boundary = DateTime.new!(Date.add(Date.utc_today(), -121), ~T[00:00:00.000000], "Etc/UTC")

    for source <- @sources do
      field = if source == "api_request_logs", do: :inserted_at, else: :timestamp
      retained = insert(source, ctx.account_id, nil, %{field => boundary})
      insert(source, ctx.account_id, nil, %{field => DateTime.add(boundary, -1, :second)})
      assert [row] = rows(source <> "_partitioned")
      assert row["seq"] == retained.seq
    end

    markers =
      Repo.query!(
        "SELECT source_table, started_at FROM log_partition_mirrors ORDER BY source_table"
      ).rows

    Repo.query!("DELETE FROM schema_migrations WHERE version = 20260927010000")

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_927_010_000, AlignLogPartitionRetention,
               prefix: ctx.schema,
               log: false
             )

    assert markers ==
             Repo.query!(
               "SELECT source_table, started_at FROM log_partition_mirrors ORDER BY source_table"
             ).rows
  end

  @tag :isolated_database
  test "retention migration repairs a pending detach in the expanded window", ctx do
    name =
      "session_logs_partitioned_" <> Calendar.strftime(Date.add(Date.utc_today(), -100), "%Y%m%d")

    opts =
      Keyword.take(
        Repo.config()
        |> Keyword.put(:database, Repo.query!("SELECT current_database()").rows |> hd() |> hd()),
        [
          :hostname,
          :port,
          :username,
          :password,
          :database,
          :socket_dir
        ]
      )

    {:ok, reader} = Postgrex.start_link(opts)
    # Keep a snapshot open in the shared test database throughout FINALIZE.
    # A private schema alone cannot isolate this database-wide wait.
    shared_opts =
      Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database, :socket_dir])

    {:ok, unrelated} = Postgrex.start_link(shared_opts)
    Postgrex.query!(unrelated, "BEGIN ISOLATION LEVEL REPEATABLE READ", [])
    Postgrex.query!(unrelated, "SELECT pg_current_snapshot()::text", [])

    try do
      Postgrex.query!(reader, "BEGIN", [])
      Postgrex.query!(reader, "SELECT * FROM #{ctx.schema}.session_logs_partitioned LIMIT 1", [])

      Repo.checkout(fn ->
        Repo.query!("SET statement_timeout = '200ms'")

        try do
          assert_raise Postgrex.Error, fn ->
            Repo.query!(
              "ALTER TABLE session_logs_partitioned DETACH PARTITION #{name} CONCURRENTLY"
            )
          end
        after
          Repo.query!("SET statement_timeout = 0")
        end
      end)

      assert Repo.query!(
               "SELECT inhdetachpending FROM pg_inherits WHERE inhrelid = $1::text::regclass",
               [name]
             ).rows == [[true]]

      Postgrex.query!(reader, "ROLLBACK", [])
      Repo.query!("DELETE FROM schema_migrations WHERE version = 20260927010000")

      assert :ok =
               Ecto.Migrator.up(Repo, 20_260_927_010_000, AlignLogPartitionRetention,
                 prefix: ctx.schema,
                 log: false
               )

      assert Repo.query!(
               "SELECT inhdetachpending FROM pg_inherits WHERE inhrelid = $1::text::regclass",
               [name]
             ).rows == [[false]]

      insert("session_logs", ctx.account_id, nil, %{
        timestamp: DateTime.add(DateTime.utc_now(), -100, :day)
      })

      assert [_] = rows("session_logs_partitioned")
    after
      GenServer.stop(reader)
      GenServer.stop(unrelated)
    end
  end

  test "backfill and cutover reject the old 90-day trigger even with ready checkpoints" do
    ready("session_logs")

    [[definition]] =
      Repo.query!("SELECT pg_get_functiondef('mirror_session_logs()'::regprocedure)").rows

    Repo.query!(String.replace(definition, "::date - 121", "::date - 90"))

    assert_raise RuntimeError, ~r/121-day retention manual migration/, fn ->
      LogTableMigration.step("session_logs")
    end

    assert_raise RuntimeError, ~r/121-day retention manual migration/, fn ->
      LogTableMigration.cutover("session_logs")
    end
  end

  test "bounded backfill, both verification passes, cutover and cleanup preserve all streams",
       ctx do
    for source <- @sources do
      live = insert(source, ctx.account_id)
      assert :progress = LogTableMigration.step(source, 1)
      assert status(source)["scanned_rows"] == 1
      ready(source)
      assert status(source)["verified_rows"] == 4
      assert :cutover = LogTableMigration.cutover(source)
      assert :already_cut_over = LogTableMigration.cutover(source)
      assert :cutover = LogTableMigration.step(source)
      assert rows(source) == rows(source <> "_legacy")
      assert Enum.map(rows(source), & &1["seq"]) == [ctx.historical[source].seq, live.seq]

      # A statement still targeting the original relation reaches the new one.
      bridged = insert(source, ctx.account_id, source <> "_legacy")
      assert length(rows(source)) == 3
      assert :cleaned_up = LogTableMigration.cleanup(source)
      assert :cleaned_up = LogTableMigration.cleanup(source)
      latest = insert(source, ctx.account_id)
      assert latest.seq > bridged.seq
      assert length(rows(source)) == 4

      assert [[true]] =
               Repo.query!("SELECT pg_get_serial_sequence($1, 'seq') IS NOT NULL", [source]).rows

      assert %{created: 0, dropped: 0} = Portal.Workers.PartitionLogTables.Database.maintain(source)
    end
  end

  test "API updates and prepared statements continue across rename", ctx do
    Repo.checkout(fn ->
      old = ctx.historical["api_request_logs"]
      assert :progress = LogTableMigration.step("api_request_logs", 1)

      {:ok, updated} =
        PortalAPI.Plugs.RequestLog.Database.update_mcp(old, %{"outcome" => "dispatched"})

      # Prepare against the old relation, then execute again after its replacement.
      Repo.query!("PREPARE read_requests AS SELECT seq FROM api_request_logs ORDER BY seq")
      ready("api_request_logs")
      assert :cutover = LogTableMigration.cutover("api_request_logs")

      {:ok, final} =
        PortalAPI.Plugs.RequestLog.Database.update_mcp(updated, %{"outcome" => "succeeded"})

      assert final.seq == old.seq
      assert final.inserted_at == old.inserted_at
      assert hd(rows("api_request_logs"))["mcp"] == %{"outcome" => "succeeded"}
      assert [[old.seq]] == Repo.query!("EXECUTE read_requests").rows
      assert :cleaned_up = LogTableMigration.cleanup("api_request_logs")
    end)
  end

  test "mixed-account session batches retain valid logs before and after cutover", ctx do
    for phase <- [:legacy, :partitioned] do
      if phase == :partitioned do
        ready("session_logs")
        assert :cutover = LogTableMigration.cutover("session_logs")
      end

      valid = %{
        account_id: ctx.account_id,
        log_id: LogId.build_session_log(),
        timestamp: DateTime.utc_now(),
        context: :client,
        subject: %{}
      }

      invalid = %{valid | account_id: Ecto.UUID.generate(), log_id: LogId.build_session_log()}
      entries = [{invalid, :invalid}, {valid, :valid}]

      assert {1, [{^invalid, :invalid}]} =
               Portal.Repo.Batch.insert_all(SessionLog, entries,
                 fk_partitions: %{
                   "session_logs_account_id_fkey" => {:simple, :account_id, Portal.Account},
                   "session_logs_partitioned_account_id_fkey" =>
                     {:simple, :account_id, Portal.Account}
                 }
               )

      assert Repo.get_by!(SessionLog, account_id: ctx.account_id, log_id: valid.log_id)
    end
  end

  test "API account constraint errors retain their Ecto changeset mapping after cutover" do
    ready("api_request_logs")
    assert :cutover = LogTableMigration.cutover("api_request_logs")

    attrs =
      Portal.APIRequestLogFixtures.valid_api_request_log_attrs()
      |> Map.put(:account_id, Ecto.UUID.generate())

    changeset = %APIRequestLog{} |> Ecto.Changeset.change(attrs) |> APIRequestLog.changeset()
    assert {:error, changeset} = Repo.insert(changeset)
    assert {"does not exist", _} = changeset.errors[:account]
  end

  test "expired rows advance the cursor without creating expired partitions", ctx do
    expired = DateTime.add(DateTime.utc_now(), -130, :day)
    insert("session_logs", ctx.account_id, "session_logs", %{timestamp: expired})
    ready("session_logs")
    assert status("session_logs")["scanned_rows"] == 2
    assert length(rows("session_logs_partitioned")) == 1
    assert :cutover = LogTableMigration.cutover("session_logs")
  end

  test "partitioned consumer deduplicates WAL replay and discards expired WAL", ctx do
    ready("change_logs")
    assert :cutover = LogTableMigration.cutover("change_logs")
    original = ctx.historical["change_logs"]

    entry =
      original |> Map.from_struct() |> Map.take(ChangeLog.__schema__(:fields)) |> Map.drop([:seq])

    replay = %{
      entry
      | log_id: LogId.build_change_log(System.os_time(:microsecond), original.lsn + 1)
    }

    assert 0 = Portal.ChangeLogs.Consumer.Database.bulk_insert([replay])

    expired = %{
      replay
      | timestamp: DateTime.add(DateTime.utc_now(), -130, :day),
        lsn: original.lsn + 2
    }

    fresh = %{replay | lsn: original.lsn + 3}
    assert 1 = Portal.ChangeLogs.Consumer.Database.bulk_insert([expired, fresh])
    assert length(rows("change_logs")) == 2
  end

  test "verification rejects missing and extra retained mirror rows" do
    source = "session_logs"
    assert :progress = LogTableMigration.step(source, 10)
    assert :progress = LogTableMigration.step(source, 10)
    assert status(source)["phase"] == "verify_source"
    Repo.query!("DELETE FROM session_logs_partitioned")
    assert_raise RuntimeError, ~r/verification failed/, fn -> LogTableMigration.step(source) end
    # Repair and resume the same verification checkpoint.
    Repo.query!("INSERT INTO session_logs_partitioned SELECT * FROM session_logs")
    assert :progress = LogTableMigration.step(source)
    assert :progress = LogTableMigration.step(source)
    assert status(source)["phase"] == "verify_mirror"
    # An extra timestamp with the same account/log ID must also be checked.
    Repo.query!(
      "INSERT INTO session_logs_partitioned (account_id, timestamp, context, subject, log_id, seq) SELECT account_id, timestamp - interval '1 day', context, subject, log_id, seq FROM session_logs"
    )

    assert_raise RuntimeError, ~r/verification failed/, fn -> LogTableMigration.step(source, 1) end
    assert_raise RuntimeError, ~r/not verified/, fn -> LogTableMigration.cutover(source) end
  end

  test "changed activation invalidates readiness and disabled mirroring blocks progress" do
    ready("session_logs")

    Repo.query!(
      "UPDATE log_partition_mirrors SET started_at = clock_timestamp() WHERE source_table = 'session_logs'"
    )

    assert_raise RuntimeError, ~r/not verified/, fn -> LogTableMigration.cutover("session_logs") end
    assert :progress = LogTableMigration.step("session_logs", 1)
    assert status("session_logs")["phase"] == "copy"
    Repo.query!("ALTER TABLE session_logs DISABLE TRIGGER mirror_partitioned_logs")

    assert_raise RuntimeError, ~r/not actively mirrored/, fn ->
      LogTableMigration.step("session_logs")
    end
  end

  test "view dependencies prevent swapping an apparently ready table" do
    ready("session_logs")
    Repo.query!("CREATE VIEW saved_sessions AS SELECT * FROM session_logs")
    assert_raise RuntimeError, ~r/dependencies/, fn -> LogTableMigration.cutover("session_logs") end
    assert status("session_logs")["phase"] == "ready"
    Repo.query!("DROP VIEW saved_sessions")
    assert :cutover = LogTableMigration.cutover("session_logs")
  end

  test "publication dependencies prevent swapping an apparently ready table", ctx do
    publication = "log_cutover_pub_#{System.unique_integer([:positive])}"
    repo = Repo.get_dynamic_repo()

    on_exit(fn ->
      Repo.put_dynamic_repo(repo)
      Repo.query!("DROP PUBLICATION IF EXISTS #{publication}")
    end)

    ready("session_logs")

    for target <- ["TABLE session_logs", "TABLES IN SCHEMA #{ctx.schema}"] do
      Repo.query!("CREATE PUBLICATION #{publication} FOR #{target}")
      assert_raise RuntimeError, ~r/dependencies/, fn -> LogTableMigration.cutover("session_logs") end
      assert status("session_logs")["phase"] == "ready"
      Repo.query!("DROP PUBLICATION #{publication}")
    end

    assert :cutover = LogTableMigration.cutover("session_logs")
  end

  test "a concurrent update cannot be skipped or overwritten by backfill" do
    with_locked_transaction("UPDATE session_logs SET subject = '{\"stage\":\"updated\"}'", fn ->
      assert_raise Postgrex.Error, ~r/lock timeout/, fn ->
        LogTableMigration.step("session_logs", 1)
      end

      refute status("session_logs")
    end)

    ready("session_logs")
    assert rows("session_logs") == rows("session_logs_partitioned")
    assert hd(rows("session_logs_partitioned"))["subject"] == %{"stage" => "updated"}
  end

  test "cutover fails quickly behind a reader and leaves both original names intact" do
    ready("session_logs")

    with_locked_transaction("LOCK TABLE session_logs IN ACCESS SHARE MODE", fn ->
      assert_raise Postgrex.Error, ~r/lock timeout/, fn ->
        LogTableMigration.cutover("session_logs")
      end

      assert status("session_logs")["phase"] == "ready"
      assert [[nil]] = Repo.query!("SELECT to_regclass('session_logs_legacy')").rows
      assert rows("session_logs") == rows("session_logs_partitioned")
    end)

    assert :cutover = LogTableMigration.cutover("session_logs")
  end

  test "backfill, cutover and maintenance share their advisory lock after rename" do
    ready("session_logs")
    assert :cutover = LogTableMigration.cutover("session_logs")

    with_locked_transaction(
      "SELECT pg_advisory_xact_lock(hashtextextended(current_schema() || '.session_logs_partitioned', 0))",
      fn ->
        assert :busy = LogTableMigration.step("session_logs")
        assert :busy = LogTableMigration.cutover("session_logs")
        assert :busy = Portal.Workers.PartitionLogTables.Database.maintain("session_logs")
      end
    )

    tomorrow = Date.add(Date.utc_today(), 1)

    assert %{created: 1, dropped: 1} =
             Portal.Workers.PartitionLogTables.Database.maintain("session_logs", tomorrow)
  end

  test "live inserts and deletes after the copy pass remain visible at cutover", ctx do
    assert :progress = LogTableMigration.step("session_logs", 1)
    later = insert("session_logs", ctx.account_id)
    Repo.delete!(ctx.historical["session_logs"])
    ready("session_logs")
    assert :cutover = LogTableMigration.cutover("session_logs")
    assert [row] = rows("session_logs")
    assert row["seq"] == later.seq
  end

  test "manual migration resumes persisted batches and completes without cutting over", ctx do
    for source <- @sources, do: assert(:progress = LogTableMigration.step(source, 1))
    assert Enum.all?(LogTableMigration.status(), &(&1["scanned_rows"] == 1))

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_928_010_000, BackfillLogTables,
               prefix: ctx.schema,
               log: false
             )

    assert Enum.all?(LogTableMigration.status(), &(&1["phase"] == "ready"))
    assert Enum.all?(LogTableMigration.status(), &(&1["scanned_rows"] == 1))

    assert [["r"]] =
             Repo.query!("SELECT relkind::text FROM pg_class WHERE oid = 'session_logs'::regclass").rows
  end

  test "failed manual backfill keeps committed progress and can be rerun", ctx do
    [[definition]] =
      Repo.query!("SELECT pg_get_functiondef('mirror_api_request_logs()'::regprocedure)").rows

    Repo.query!(String.replace(definition, "::date - 121", "::date - 90"))

    assert_raise RuntimeError, ~r/121-day retention manual migration/, fn ->
      Ecto.Migrator.up(Repo, 20_260_928_010_000, BackfillLogTables, prefix: ctx.schema, log: false)
    end

    assert status("session_logs")["phase"] == "ready"
    assert status("session_logs")["scanned_rows"] == 1

    assert [[false]] =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = 20260928010000)"
             ).rows

    Repo.query!(definition)

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_928_010_000, BackfillLogTables,
               prefix: ctx.schema,
               log: false
             )

    assert Enum.all?(LogTableMigration.status(), &(&1["phase"] == "ready"))
    assert Enum.all?(LogTableMigration.status(), &(&1["scanned_rows"] == 1))
  end

  test "cleanup requires cutover and removes all rollout objects while preserving data and sequences",
       ctx do
    assert_raise Postgrex.Error, ~r/Complete log-table cutover/, fn ->
      Ecto.Migrator.up(Repo, 20_260_929_000_000, RequirePartitionedLogTables,
        prefix: ctx.schema,
        log: false
      )
    end

    assert_raise Postgrex.Error, ~r/has not been cut over/, fn -> cleanup(ctx.schema) end

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_928_010_000, BackfillLogTables,
               prefix: ctx.schema,
               log: false
             )

    assert_raise RuntimeError, ~r/preceding release/, fn ->
      Ecto.Migrator.up(Repo, 20_260_928_020_000, CutOverLogTables, prefix: ctx.schema, log: false)
    end

    for source <- @sources, do: assert(:cutover = LogTableMigration.cutover(source))

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_928_020_000, CutOverLogTables,
               prefix: ctx.schema,
               log: false
             )

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_929_000_000, RequirePartitionedLogTables,
               prefix: ctx.schema,
               log: false
             )

    Repo.query!(
      "INSERT INTO oban_jobs (worker, state) VALUES ('Portal.Workers.DeleteOldSessionLogs', 'executing')"
    )

    assert_raise Postgrex.Error, ~r/still executing/, fn -> cleanup(ctx.schema) end
    Repo.query!("UPDATE oban_jobs SET state = 'completed'")

    Repo.query!(
      "INSERT INTO oban_jobs (worker, state) VALUES ('Portal.Workers.PartitionLogTables', 'available')"
    )

    assert :ok = cleanup(ctx.schema)

    assert [[nil, nil]] =
             Repo.query!(
               "SELECT to_regclass('log_table_backfills'), to_regclass('log_partition_mirrors')"
             ).rows

    assert [["Portal.Workers.PartitionLogTables"]] =
             Repo.query!("SELECT worker FROM oban_jobs").rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM pg_trigger WHERE tgname = 'mirror_partitioned_logs' AND tgrelid IN (SELECT oid FROM pg_class WHERE relnamespace = current_schema()::regnamespace)"
             ).rows

    for source <- @sources do
      assert [[nil, nil]] =
               Repo.query!("SELECT to_regclass($1), to_regprocedure($2)", [
                 source <> "_legacy",
                 "mirror_" <> source <> "()"
               ]).rows

      assert [row] = rows(source)
      assert row["seq"] == ctx.historical[source].seq
      assert insert(source, ctx.account_id).seq > row["seq"]
      assert %{created: 0, dropped: 0} = Portal.Workers.PartitionLogTables.Database.maintain(source)
    end

    # The DDL committed before a hypothetical migration-version write failure.
    Repo.query!("DELETE FROM schema_migrations WHERE version = 20260929010000")
    assert :ok = cleanup(ctx.schema)
    Repo.query!("DELETE FROM accounts WHERE id = $1::text::uuid", [ctx.account_id])
    for source <- @sources, do: assert(rows(source) == [])
  end

  test "cleanup rolls back all drops if a legacy table identity is wrong", ctx do
    for source <- @sources do
      ready(source)
      assert :cutover = LogTableMigration.cutover(source)
    end

    Repo.query!(
      "UPDATE log_table_backfills SET context = jsonb_set(context, '{source_oid}', '0') WHERE source_table = 'api_request_logs'"
    )

    assert_raise Postgrex.Error, ~r/Unexpected cutover state/, fn -> cleanup(ctx.schema) end

    for source <- @sources do
      assert [[oid]] = Repo.query!("SELECT to_regclass($1)", [source <> "_legacy"]).rows
      assert is_integer(oid)
    end
  end

  defp cleanup(schema),
    do:
      Ecto.Migrator.up(Repo, 20_260_929_010_000, RemoveLogPartitionRolloutState,
        prefix: schema,
        log: false
      )

  defp with_locked_transaction(sql, fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(sql)
          send(parent, {:locked, self()})

          receive do
            :release -> :ok
          after
            10_000 -> raise "Lock test did not release transaction"
          end
        end)
      end)

    assert_receive {:locked, pid}, 5_000

    try do
      fun.()
    after
      send(pid, :release)
      Task.await(task, 5_000)
    end
  end

  defp ready(source, remaining \\ 30)
  defp ready(_source, 0), do: flunk("Backfill did not reach ready")

  defp ready(source, remaining) do
    case LogTableMigration.step(source, 1) do
      :ready -> :ok
      :progress -> ready(source, remaining - 1)
    end
  end

  defp status(source), do: Enum.find(LogTableMigration.status(), &(&1["source_table"] == source))

  defp rows(source),
    do: Repo.query!("SELECT to_jsonb(s) FROM #{source} s ORDER BY seq").rows |> List.flatten()

  defp insert(source, account_id, table \\ nil, attrs \\ %{}) do
    now = DateTime.utc_now()

    {schema, row} =
      case source do
        "session_logs" ->
          {SessionLog,
           %{log_id: LogId.build_session_log(), timestamp: now, context: :client, subject: %{}}}

        "api_request_logs" ->
          {APIRequestLog,
           Portal.APIRequestLogFixtures.valid_api_request_log_attrs() |> Map.put(:inserted_at, now)}

        "change_logs" ->
          lsn = System.unique_integer([:positive, :monotonic])

          {ChangeLog,
           %{
             log_id: LogId.build_change_log(System.os_time(:microsecond), lsn),
             timestamp: now,
             lsn: lsn,
             object: "accounts",
             operation: :insert,
             after: %{},
             vsn: 0
           }}
      end

    row = row |> Map.put(:account_id, account_id) |> Map.merge(attrs)
    {1, [log]} = Repo.insert_all({table || source, schema}, [row], returning: true)
    log
  end
end
