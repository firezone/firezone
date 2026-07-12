defmodule Portal.Replication.SlotPollerTest do
  use Portal.DataCase, async: true

  import Portal.Test.Assertions

  alias Portal.Replication.SlotPoller

  # Forwards every callback to the test process. The test pid travels via the
  # Portal.Config process-dictionary override, resolved from the poller
  # process through its $ancestors chain.
  defmodule TestConsumer do
    @behaviour Portal.Replication.SlotPoller

    @impl true
    def init_state(_config) do
      test_pid = Portal.Config.get_env(:portal, :slot_poller_test_pid)
      send(test_pid, :init_state)
      %{test_pid: test_pid}
    end

    @impl true
    def on_begin(state, _msg), do: state

    @impl true
    def on_logical_message(state, msg) do
      send(state.test_pid, {:logical_message, msg.prefix, msg.content, msg.transactional})
      state
    end

    @impl true
    def on_write(state, lsn, op, table, old_data, data) do
      # Simulates a hook whose inner transaction rolls back as part of normal
      # operation; the poll cycle must tolerate it
      if data && data["val"] == "rollback" do
        {:error, :poison} = Portal.Repo.transaction(fn -> Portal.Repo.rollback(:poison) end)
      end

      send(state.test_pid, {:write, lsn, op, table, old_data, data})

      # Simulates a consumer raising undefined_object (42704) for something
      # that is not the slot or the publication
      if data && data["val"] == "undefined-object" do
        Portal.Repo.query!("SELECT NULL::nonexistent_type", [])
      end

      state
    end

    @impl true
    def flush(state) do
      send(state.test_pid, :flush)
      state
    end
  end

  setup do
    uid = System.unique_integer([:positive])
    slot = "test_poller_slot_#{uid}"
    publication = "test_poller_pub_#{uid}"
    table = "test_poller_tbl_#{uid}"
    prefix = "test_prefix_#{uid}"
    region = "test_region_#{uid}"

    # Non-sandboxed connection: its DDL and writes commit for real so they
    # reach the WAL, unlike sandboxed writes which never commit. The slot and
    # publication are pre-created here because Postgres refuses to create a
    # logical slot inside a transaction that has performed writes, which the
    # sandbox wrapping transaction may have; the poller then takes its
    # exists-paths, which are transaction-safe.
    aux = start_supervised!({Postgrex, aux_config()})
    Postgrex.query!(aux, "CREATE TABLE #{table} (id int PRIMARY KEY, val text)", [])
    Postgrex.query!(aux, "CREATE PUBLICATION #{publication} FOR TABLE #{table}", [])
    Postgrex.query!(aux, "SELECT pg_create_logical_replication_slot($1, 'pgoutput')", [slot])

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(aux_config())
      Postgrex.query(cleanup, "SELECT pg_drop_replication_slot($1)", [slot])
      Postgrex.query(cleanup, "DROP PUBLICATION IF EXISTS #{publication}", [])
      Postgrex.query(cleanup, "DROP TABLE IF EXISTS #{table}", [])
      GenServer.stop(cleanup)
    end)

    # Base app env so put_env_override can merge; constant, so concurrent
    # tests writing it is benign.
    Application.put_env(:portal, TestConsumer, [])

    Portal.Config.put_env_override(:slot_poller_test_pid, self())

    Portal.Config.put_env_override(TestConsumer,
      repo: Portal.Repo,
      replication_slot_name: slot,
      publication_name: publication,
      table_subscriptions: [table],
      region: region,
      poll_interval: 25,
      # The first setup attempt can race the sandbox allowance in
      # start_poller!/1, so retry quickly instead of production's 5s
      setup_retry_interval: 25,
      batch_size: 500,
      warning_threshold: :timer.minutes(5),
      error_threshold: :timer.minutes(10)
    )

    %{
      aux: aux,
      slot: slot,
      publication: publication,
      table: table,
      prefix: prefix,
      region: region
    }
  end

  test "polls the slot and dispatches decoded changes", %{
    aux: aux,
    slot: slot,
    table: table,
    prefix: prefix
  } do
    start_poller!()

    Postgrex.query!(aux, "INSERT INTO #{table} (id, val) VALUES (1, 'hello')", [])
    Postgrex.query!(aux, "SELECT pg_logical_emit_message(true, $1, 'payload')", [prefix])

    assert_receive {:write, lsn, :insert, ^table, nil, %{"id" => "1", "val" => "hello"}}, 5000
    assert_receive {:logical_message, ^prefix, "payload", true}, 5000
    assert_receive :flush, 5000
    assert is_integer(lsn) and lsn > 0

    # The slot advances past the processed batch, so nothing replays
    wait_for(fn ->
      %{rows: [[confirmed]]} =
        Postgrex.query!(
          aux,
          "SELECT (confirmed_flush_lsn - '0/0'::pg_lsn)::bigint FROM pg_replication_slots WHERE slot_name = $1",
          [slot]
        )

      assert confirmed > lsn
    end)
  end

  test "dispatches updates and deletes with old tuple data", %{
    aux: aux,
    table: table
  } do
    start_poller!()

    Postgrex.query!(aux, "INSERT INTO #{table} (id, val) VALUES (2, 'before')", [])
    Postgrex.query!(aux, "UPDATE #{table} SET val = 'after' WHERE id = 2", [])
    Postgrex.query!(aux, "DELETE FROM #{table} WHERE id = 2", [])

    assert_receive {:write, _, :insert, ^table, nil, %{"val" => "before"}}, 5000
    assert_receive {:write, _, :update, ^table, _old, %{"val" => "after"}}, 5000
    assert_receive {:write, _, :delete, ^table, old_data, nil}, 5000
    assert old_data["id"] == "2"
  end

  test "does not poll while another session holds the leadership lock", %{
    aux: aux,
    slot: slot,
    table: table,
    region: region
  } do
    test_pid = self()

    # Hold the poller's advisory lock from a separate database session
    holder =
      Task.async(fn ->
        Postgrex.transaction(aux, fn conn ->
          %{rows: [[true]]} =
            Postgrex.query!(conn, "SELECT pg_try_advisory_xact_lock(hashtext($1))", [
              "#{slot}/#{region}"
            ])

          send(test_pid, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 5000

    start_poller!()
    Postgrex.query!(aux, "INSERT INTO #{table} (id, val) VALUES (3, 'once')", [])

    refute_receive {:write, _, :insert, ^table, nil, %{"id" => "3"}}, 500

    send(holder.pid, :release)
    Task.await(holder)

    assert_receive {:write, _, :insert, ^table, nil, %{"id" => "3"}}, 5000
    refute_receive {:write, _, :insert, ^table, nil, %{"id" => "3"}}, 500
  end

  test "consumer-internal transaction rollbacks do not abort the cycle", %{
    aux: aux,
    slot: slot,
    table: table
  } do
    start_poller!()

    Postgrex.query!(aux, "INSERT INTO #{table} (id, val) VALUES (5, 'rollback')", [])

    assert_receive {:write, lsn, :insert, ^table, nil, %{"id" => "5"}}, 5000

    # The batch still flushes and the slot advances past it
    wait_for(fn ->
      %{rows: [[confirmed]]} =
        Postgrex.query!(
          aux,
          "SELECT (confirmed_flush_lsn - '0/0'::pg_lsn)::bigint FROM pg_replication_slots WHERE slot_name = $1",
          [slot]
        )

      assert confirmed > lsn
    end)
  end

  test "recreates the slot when it is dropped at runtime", %{
    aux: aux,
    slot: slot,
    table: table
  } do
    start_poller!()
    assert_receive :init_state, 5000

    Postgrex.query!(aux, "INSERT INTO #{table} (id, val) VALUES (6, 'before-drop')", [])
    assert_receive {:write, _, :insert, ^table, nil, %{"id" => "6"}}, 5000

    # The drop can race an in-flight peek that holds the slot active; retry
    wait_for(fn ->
      assert {:ok, _} = Postgrex.query(aux, "SELECT pg_drop_replication_slot($1)", [slot])
    end)

    # The recreated slot is visible before creation finds its consistent
    # point, which can take a while under concurrent test transactions; only
    # rows written after confirmed_flush_lsn is set are decodable
    wait_for(
      fn ->
        %{rows: rows} =
          Postgrex.query!(
            aux,
            "SELECT 1 FROM pg_replication_slots WHERE slot_name = $1 AND confirmed_flush_lsn IS NOT NULL",
            [slot]
          )

        assert rows == [[1]]
      end,
      30
    )

    # Recreation went through setup, which re-initialized the consumer
    assert_receive :init_state, 5000

    Postgrex.query!(aux, "INSERT INTO #{table} (id, val) VALUES (7, 'after-recreate')", [])

    assert_receive {:write, _, :insert, ^table, nil, %{"id" => "7", "val" => "after-recreate"}},
                   5000
  end

  test "unrelated undefined_object errors replay instead of re-running setup", %{
    aux: aux,
    table: table
  } do
    start_poller!()
    assert_receive :init_state, 5000

    Postgrex.query!(aux, "INSERT INTO #{table} (id, val) VALUES (8, 'undefined-object')", [])

    # The failed cycle replays through the ordinary error path
    assert_receive {:write, _, :insert, ^table, nil, %{"id" => "8"}}, 5000
    assert_receive {:write, _, :insert, ^table, nil, %{"id" => "8"}}, 5000
    refute_receive :init_state, 500
  end

  test "resumes from retained WAL after a restart", %{
    aux: aux,
    table: table
  } do
    pid = start_poller!()

    stop_supervised!(:poller_1)
    refute Process.alive?(pid)

    # Written while no poller is running; the durable slot retains it
    Postgrex.query!(aux, "INSERT INTO #{table} (id, val) VALUES (4, 'while-down')", [])

    start_poller!(:poller_2)

    assert_receive {:write, _, :insert, ^table, nil, %{"id" => "4", "val" => "while-down"}}, 5000
  end

  defp start_poller!(id \\ :poller_1) do
    pid =
      start_supervised!(
        Supervisor.child_spec({SlotPoller, consumer: TestConsumer}, id: id),
        restart: :temporary
      )

    Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, self(), pid)

    wait_for(fn ->
      assert :sys.get_state(pid).consumer_state
    end)

    pid
  end

  # pool_size 2: the leadership-lock test holds one connection inside a
  # transaction while other queries keep flowing on the second
  defp aux_config do
    Portal.Repo.config()
    |> Keyword.drop([:pool])
    |> Keyword.put(:pool_size, 2)
  end
end
