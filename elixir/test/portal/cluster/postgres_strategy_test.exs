defmodule Portal.Cluster.PostgresStrategyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Portal.Test.Assertions

  alias Portal.Cluster.PostgresStrategy

  describe "heartbeat and goodbye via LISTEN/NOTIFY" do
    test "broadcasts heartbeat on startup and goodbye on termination" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      listener = start_supervised!({Postgrex.Notifications, Portal.Repo.config()})
      {:ok, _ref} = Postgrex.Notifications.listen(listener, channel_name)

      # Use a short heartbeat_interval so connection retries happen quickly
      # in case of transient too_many_connections errors under concurrent test load.
      _pid =
        start_supervised!(
          {PostgresStrategy, [build_state(channel_name: channel_name, heartbeat_interval: 100)]}
        )

      assert_receive {:notification, _, _, ^channel_name, "heartbeat:" <> _}, 5000
      flush_notifications()

      stop_supervised!(PostgresStrategy)
      assert_receive {:notification, _, _, ^channel_name, "goodbye:" <> _}, 5000
    end
  end

  describe "handle_info/2" do
    test ":heartbeat emits telemetry and schedules next heartbeat" do
      channel_name = "test_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        "test-handler-#{channel_name}",
        [:portal, :cluster],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:telemetry, measurements})
        end,
        nil
      )

      _pid =
        start_supervised!(
          {PostgresStrategy, [build_state(channel_name: channel_name, heartbeat_interval: 50)]}
        )

      # Should receive telemetry events
      assert_receive {:telemetry, %{discovered_nodes_count: 0}}, 1000

      :telemetry.detach("test-handler-#{channel_name}")
    end

    test "handles notification from other nodes" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      listener = start_supervised!({Postgrex.Notifications, Portal.Repo.config()})
      {:ok, _ref} = Postgrex.Notifications.listen(listener, channel_name)

      pid = start_strategy(channel_name: channel_name)
      flush_notifications()

      # Simulate a heartbeat from another node by sending directly to the process
      send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})

      wait_for_connected_node(pid, :other@node)

      assert Process.alive?(pid)
    end

    test "logs error when connecting to node fails" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name, connect_fn: :mock_connect_failing)

      log =
        capture_log(fn ->
          send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})
          sync(pid)
          Logger.flush()
        end)

      assert log =~ "unable to connect to"
      assert Process.alive?(pid)
    end

    test "handles goodbye notification from connected nodes" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      # First connect the node via heartbeat
      send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})
      wait_for_connected_node(pid, :other@node)

      log =
        capture_log(fn ->
          send(pid, {:notification, self(), make_ref(), channel_name, "goodbye:other@node"})
          sync(pid)
          Logger.flush()
        end)

      assert log =~ "Received goodbye from node"
      assert Process.alive?(pid)
    end

    test "ignores goodbye from nodes that were never connected" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      log =
        capture_log(fn ->
          send(pid, {:notification, self(), make_ref(), channel_name, "goodbye:unknown@node"})
          sync(pid)
          Logger.flush()
        end)

      refute log =~ "Received goodbye from node"
      assert Process.alive?(pid)
    end

    test "only disconnects once when receiving duplicate goodbyes" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      # First connect the node via heartbeat
      send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})
      wait_for_connected_node(pid, :other@node)

      log =
        capture_log(fn ->
          # Send two goodbyes in quick succession
          send(pid, {:notification, self(), make_ref(), channel_name, "goodbye:other@node"})
          send(pid, {:notification, self(), make_ref(), channel_name, "goodbye:other@node"})
          sync(pid)
          Logger.flush()
        end)

      # Should only log disconnect once
      assert length(Regex.scan(~r/Received goodbye from node/, log)) == 1
      assert Process.alive?(pid)
    end

    test "handles unknown notifications gracefully" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      # Send unknown notification
      send(pid, {:notification, self(), make_ref(), channel_name, "unknown:payload"})
      sync(pid)

      assert Process.alive?(pid)
    end

    test "handles unknown messages gracefully" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      send(pid, :some_random_message)
      sync(pid)

      assert Process.alive?(pid)
    end

    test "reconnects when listener dies" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      # Get the listener pid from state and kill it
      state = :sys.get_state(pid)
      listener_pid = state.listener_pid

      log =
        capture_log(fn ->
          ref = Process.monitor(listener_pid)
          Process.exit(listener_pid, :kill)
          # Wait for the process to actually die before checking GenServer state
          receive do
            {:DOWN, ^ref, :process, ^listener_pid, _} -> :ok
          end

          sync(pid)
          Logger.flush()
        end)

      assert log =~ "PostgreSQL listener died, reconnecting"
      assert Process.alive?(pid)
    end

    test "reconnects when notify connection dies" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      state = :sys.get_state(pid)
      notify_conn = state.notify_conn

      log =
        capture_log(fn ->
          ref = Process.monitor(notify_conn)
          Process.exit(notify_conn, :kill)
          # Wait for the process to actually die before checking GenServer state
          receive do
            {:DOWN, ^ref, :process, ^notify_conn, _} -> :ok
          end

          sync(pid)
          Logger.flush()
        end)

      assert log =~ "PostgreSQL notify connection died, reconnecting"
      assert Process.alive?(pid)
    end
  end

  describe "stale node detection" do
    test "disconnects stale nodes and logs" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PostgresStrategy,
           [build_state(channel_name: channel_name, heartbeat_interval: 50, missed_heartbeats: 1)]}
        )
      wait_for_started(pid)

      # Manually inject a stale node into state
      state = :sys.get_state(pid)
      stale_time = System.monotonic_time(:millisecond) - 200

      new_state = %{
        state
        | node_timestamps: %{:stale@node => stale_time},
          connected_nodes: [:stale@node]
      }

      :sys.replace_state(pid, fn _ -> new_state end)

      log =
        capture_log(fn ->
          # Trigger heartbeat which checks stale nodes
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      assert log =~ "Disconnecting stale nodes"

      # Verify node was removed
      final_state = :sys.get_state(pid)
      refute Map.has_key?(final_state.node_timestamps, :stale@node)
    end
  end

  describe "threshold logging" do
    test "does not log error on first threshold violation" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PostgresStrategy,
           [build_state(channel_name: channel_name, node_count: 5, heartbeat_interval: 50)]}
        )
      wait_for_started(pid)

      # Inject a stale node
      state = :sys.get_state(pid)
      stale_time = System.monotonic_time(:millisecond) - 200

      new_state = %{
        state
        | node_timestamps: %{:node1@test => stale_time},
          connected_nodes: [:node1@test],
          missed_heartbeats: 1,
          below_threshold?: false
      }

      :sys.replace_state(pid, fn _ -> new_state end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      # Should NOT log on first violation — enters pending state instead
      refute log =~ "Connected nodes count is below threshold"

      state = :sys.get_state(pid)
      assert match?({:pending, _}, state.below_threshold?)
    end

    test "logs error after sustained threshold violation" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PostgresStrategy,
           [build_state(channel_name: channel_name, node_count: 5, heartbeat_interval: 50)]}
        )
      wait_for_started(pid)

      # Inject a stale node with below_threshold? already pending from the past
      state = :sys.get_state(pid)
      stale_time = System.monotonic_time(:millisecond) - 200

      new_state = %{
        state
        | node_timestamps: %{:node1@test => stale_time},
          connected_nodes: [:node1@test],
          missed_heartbeats: 1,
          below_threshold?: {:pending, System.monotonic_time(:millisecond) - :timer.seconds(60)}
      }

      :sys.replace_state(pid, fn _ -> new_state end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      assert log =~ "Connected nodes count is below threshold"

      state = :sys.get_state(pid)
      assert state.below_threshold? == true
    end

    test "logs recovery when coming back above threshold" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PostgresStrategy, [build_state(channel_name: channel_name, node_count: 1)]}
        )
      wait_for_started(pid)

      # Set state to below threshold (sustained violation already logged)
      state = :sys.get_state(pid)
      new_state = %{state | below_threshold?: true, connected_nodes: []}
      :sys.replace_state(pid, fn _ -> new_state end)

      log =
        capture_log(fn ->
          send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})
          sync(pid)
          Logger.flush()
        end)

      assert log =~ "Connected nodes count is back above threshold"
    end

    test "does not log recovery from pending state" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PostgresStrategy, [build_state(channel_name: channel_name, node_count: 1)]}
        )
      wait_for_started(pid)

      # Set state to pending (error was never logged)
      state = :sys.get_state(pid)

      new_state = %{
        state
        | below_threshold?: {:pending, System.monotonic_time(:millisecond)},
          connected_nodes: []
      }

      :sys.replace_state(pid, fn _ -> new_state end)

      log =
        capture_log(fn ->
          send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})
          sync(pid)
          Logger.flush()
        end)

      # Should NOT log recovery since the error was never logged
      refute log =~ "Connected nodes count is back above threshold"

      state = :sys.get_state(pid)
      assert state.below_threshold? == false
    end
  end

  describe "notify edge cases" do
    test "does not crash when notify_conn is nil" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      # Set notify_conn to nil
      state = :sys.get_state(pid)
      :sys.replace_state(pid, fn _ -> %{state | notify_conn: nil} end)

      # This should not crash
      send(pid, :heartbeat)
      sync(pid)

      assert Process.alive?(pid)
    end

    test "logs error when notify fails due to dead connection" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      # Replace notify_conn with a dead pid (simulate broken connection)
      state = :sys.get_state(pid)
      {dead_pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, :normal}
      :sys.replace_state(pid, fn _ -> %{state | notify_conn: dead_pid} end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      assert log =~ "Failed to send cluster notification"
    end

    test "logs error when pg_notify returns SQL error" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      # Inject an oversized channel name that exceeds PostgreSQL's limit
      state = :sys.get_state(pid)
      long_channel = String.duplicate("x", 9000)
      :sys.replace_state(pid, fn _ -> %{state | channel_name: long_channel} end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      assert log =~ "Failed to send cluster notification"
    end
  end

  describe "connection failure" do
    test "logs error and schedules retry on connection failure" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      # Kill both connections to simulate failure
      state = :sys.get_state(pid)
      listener_ref = Process.monitor(state.listener_pid)
      notify_ref = Process.monitor(state.notify_conn)
      Process.exit(state.listener_pid, :kill)
      Process.exit(state.notify_conn, :kill)
      assert_receive {:DOWN, ^listener_ref, :process, _, _}
      assert_receive {:DOWN, ^notify_ref, :process, _, _}

      # Set connections to nil and trigger retry
      :sys.replace_state(pid, fn s -> %{s | listener_pid: nil, notify_conn: nil} end)

      send(pid, :retry_connect)

      wait_for(fn ->
        assert Process.alive?(pid)
        new_state = :sys.get_state(pid)
        assert new_state.listener_pid != nil
        assert new_state.notify_conn != nil
      end)
    end

    test "forwards :configure from the repo config to both connections" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      Portal.Config.put_env_override(
        __MODULE__.ConfigureRepo,
        {__MODULE__, :mock_configure, [self()]}
      )

      start_strategy(channel_name: channel_name, repo: __MODULE__.ConfigureRepo)

      # One connect per connection: notify_conn and the listener
      assert_receive :configure_called, 5000
      assert_receive :configure_called, 5000
    end

    test "logs error when initial connection fails" do
      log =
        capture_log(fn ->
          # Use a repo with invalid config to trigger connection failure
          state = build_state_with_invalid_repo()
          {:ok, pid} = GenServer.start_link(PostgresStrategy, [state])
          sync(pid)
          Logger.flush()
          GenServer.stop(pid, :normal)
        end)

      assert log =~ "Failed to start PostgreSQL connections"
    end
  end

  describe "threshold recovery edge case" do
    test "does not log recovery when still below threshold" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PostgresStrategy,
           [build_state(channel_name: channel_name, node_count: 10, heartbeat_interval: 50)]}
        )
      wait_for_started(pid)

      # Set state with below_threshold? as false and only 1 connected node
      # When we add another node via heartbeat, we'll still be below 10 nodes
      state = :sys.get_state(pid)

      new_state = %{
        state
        | below_threshold?: false,
          connected_nodes: [:node1@test],
          node_timestamps: %{:node1@test => System.monotonic_time(:millisecond)}
      }

      :sys.replace_state(pid, fn _ -> new_state end)

      # Simulate heartbeat from another node - now we have 2 nodes + self = 3, still below 10
      log =
        capture_log(fn ->
          send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:node2@test"})
          sync(pid)
          Logger.flush()
        end)

      # Should not log recovery since we're still below threshold
      refute log =~ "Connected nodes count is back above threshold"
    end
  end

  # Helpers

  defp build_state(opts) do
    connect_fn = Keyword.get(opts, :connect_fn, :mock_connect)

    %{
      topology: :test_topology,
      connect: {__MODULE__, connect_fn, []},
      disconnect: {__MODULE__, :mock_disconnect, []},
      list_nodes: {__MODULE__, :mock_list_nodes, []},
      config:
        [
          repo: Keyword.get(opts, :repo, Portal.Repo),
          channel_name: Keyword.get(opts, :channel_name, "test_cluster"),
          heartbeat_interval: Keyword.get(opts, :heartbeat_interval, 60_000),
          missed_heartbeats: Keyword.get(opts, :missed_heartbeats, 3),
          node_count: Keyword.get(opts, :node_count, nil)
        ]
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
    }
  end

  defp build_state_with_invalid_repo do
    %{
      topology: :test_topology,
      connect: {__MODULE__, :mock_connect, []},
      disconnect: {__MODULE__, :mock_disconnect, []},
      list_nodes: {__MODULE__, :mock_list_nodes, []},
      config: [
        repo: __MODULE__.InvalidRepo,
        channel_name: "test_cluster",
        heartbeat_interval: 100
      ]
    }
  end

  defp flush_notifications do
    receive do
      {:notification, _, _, _, _} -> flush_notifications()
    after
      0 -> :ok
    end
  end

  defp start_strategy(opts) do
    pid = start_supervised!({PostgresStrategy, [build_state(opts)]})
    wait_for_started(pid)
    pid
  end

  defp wait_for_started(pid) do
    wait_for(fn ->
      state = :sys.get_state(pid)
      assert state.listener_pid != nil
      assert state.notify_conn != nil
    end)
  end

  defp wait_for_connected_node(pid, node) do
    wait_for(fn ->
      state = :sys.get_state(pid)
      assert node in state.connected_nodes
    end)
  end

  # Forces a synchronous round-trip through the GenServer so prior async
  # messages are handled before the test continues.
  defp sync(pid), do: :sys.get_state(pid)

  # Mock functions for Cluster.Strategy callbacks
  def mock_connect(_node), do: true
  def mock_disconnect(_node), do: true
  def mock_list_nodes, do: []
  def mock_connect_failing(_node), do: false

  def mock_configure(opts, test_pid) do
    send(test_pid, :configure_called)
    opts
  end

  # Mock repo module that returns invalid config
  defmodule InvalidRepo do
    def config do
      [hostname: "invalid.host.that.does.not.exist", port: 9999, connect_timeout: 100]
    end
  end

  # Mock repo whose config carries a :configure hook, like production does when
  # DATABASE_ENTRA_AUTH is enabled. The hook MFA (with the test pid in its args)
  # arrives via Portal.Config.put_env_override from the calling test.
  defmodule ConfigureRepo do
    def config do
      Keyword.put(Portal.Repo.config(), :configure, Portal.Config.get_env(:portal, __MODULE__))
    end
  end
end
