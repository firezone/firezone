defmodule Portal.Cluster.PostgresStrategyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Portal.Cluster.PostgresStrategy

  describe "heartbeat and goodbye via LISTEN/NOTIFY" do
    test "broadcasts heartbeat on startup and goodbye on termination" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      listener = start_supervised!({Postgrex.Notifications, Portal.Repo.config()})
      {:ok, _ref} = Postgrex.Notifications.listen(listener, channel_name)

      _pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      assert_receive {:notification, _, _, ^channel_name, "heartbeat:" <> _}, 1000
      flush_notifications()

      stop_supervised!(PostgresStrategy)
      assert_receive {:notification, _, _, ^channel_name, "goodbye:" <> _}, 1000
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

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)
      flush_notifications()

      # Simulate a heartbeat from another node by sending directly to the process
      send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})
      Process.sleep(50)

      # The strategy should have tried to connect (will fail since node doesn't exist)
      # We just verify it doesn't crash
      assert Process.alive?(pid)
    end

    test "logs error when connecting to node fails" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PostgresStrategy,
           [build_state(channel_name: channel_name, connect_fn: :mock_connect_failing)]}
        )

      Process.sleep(100)

      log =
        capture_log(fn ->
          send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})
          Process.sleep(50)
        end)

      assert log =~ "unable to connect to"
      assert Process.alive?(pid)
    end

    test "handles goodbye notification from other nodes" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      log =
        capture_log(fn ->
          send(pid, {:notification, self(), make_ref(), channel_name, "goodbye:other@node"})
          Process.sleep(50)
        end)

      assert log =~ "Received goodbye from node"
      assert Process.alive?(pid)
    end

    test "handles unknown notifications gracefully" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      # Send unknown notification
      send(pid, {:notification, self(), make_ref(), channel_name, "unknown:payload"})
      Process.sleep(50)

      assert Process.alive?(pid)
    end

    test "handles unknown messages gracefully" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      send(pid, :some_random_message)
      Process.sleep(50)

      assert Process.alive?(pid)
    end

    test "reconnects when listener dies" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      # Get the listener pid from state and kill it
      state = :sys.get_state(pid)
      listener_pid = state.listener_pid

      log =
        capture_log(fn ->
          Process.exit(listener_pid, :kill)
          Process.sleep(200)
        end)

      assert log =~ "PostgreSQL listener died, reconnecting"
      assert Process.alive?(pid)
    end

    test "reconnects when notify connection dies" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      state = :sys.get_state(pid)
      notify_conn = state.notify_conn

      log =
        capture_log(fn ->
          Process.exit(notify_conn, :kill)
          Process.sleep(200)
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

      Process.sleep(100)

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
          Process.sleep(100)
        end)

      assert log =~ "Disconnecting stale nodes"

      # Verify node was removed
      final_state = :sys.get_state(pid)
      refute Map.has_key?(final_state.node_timestamps, :stale@node)
    end
  end

  describe "threshold logging" do
    test "logs error when falling below threshold" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PostgresStrategy,
           [build_state(channel_name: channel_name, node_count: 5, heartbeat_interval: 50)]}
        )

      Process.sleep(100)

      # Inject a node and then simulate it going stale
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
          Process.sleep(100)
        end)

      assert log =~ "Connected nodes count is below threshold"
    end

    test "logs recovery when coming back above threshold" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PostgresStrategy, [build_state(channel_name: channel_name, node_count: 1)]}
        )

      Process.sleep(100)

      # Set state to below threshold
      state = :sys.get_state(pid)
      new_state = %{state | below_threshold?: true, connected_nodes: []}
      :sys.replace_state(pid, fn _ -> new_state end)

      log =
        capture_log(fn ->
          # Simulate successful heartbeat from another node
          send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})
          Process.sleep(100)
        end)

      assert log =~ "Connected nodes count is back above threshold"
    end
  end

  describe "notify edge cases" do
    test "does not crash when notify_conn is nil" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      # Set notify_conn to nil
      state = :sys.get_state(pid)
      :sys.replace_state(pid, fn _ -> %{state | notify_conn: nil} end)

      # This should not crash
      send(pid, :heartbeat)
      Process.sleep(50)

      assert Process.alive?(pid)
    end

    test "logs error when notify fails due to dead connection" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      # Replace notify_conn with a dead pid (simulate broken connection)
      state = :sys.get_state(pid)
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      :sys.replace_state(pid, fn _ -> %{state | notify_conn: dead_pid} end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          Process.sleep(100)
        end)

      assert log =~ "Failed to send cluster notification"
    end

    test "logs error when pg_notify returns SQL error" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      # Inject an oversized channel name that exceeds PostgreSQL's limit
      state = :sys.get_state(pid)
      long_channel = String.duplicate("x", 9000)
      :sys.replace_state(pid, fn _ -> %{state | channel_name: long_channel} end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          Process.sleep(100)
        end)

      assert log =~ "Failed to send cluster notification"
    end
  end

  describe "connection failure" do
    test "logs error and schedules retry on connection failure" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_supervised!({PostgresStrategy, [build_state(channel_name: channel_name)]})
      Process.sleep(100)

      # Kill both connections to simulate failure
      state = :sys.get_state(pid)
      Process.exit(state.listener_pid, :kill)
      Process.exit(state.notify_conn, :kill)
      Process.sleep(50)

      # Set connections to nil and trigger retry
      :sys.replace_state(pid, fn s -> %{s | listener_pid: nil, notify_conn: nil} end)

      send(pid, :retry_connect)
      Process.sleep(200)

      # Should have reconnected successfully
      assert Process.alive?(pid)
      new_state = :sys.get_state(pid)
      assert new_state.listener_pid != nil
      assert new_state.notify_conn != nil
    end

    test "logs error when initial connection fails" do
      log =
        capture_log(fn ->
          # Use a repo with invalid config to trigger connection failure
          state = build_state_with_invalid_repo()
          {:ok, pid} = GenServer.start_link(PostgresStrategy, [state])
          Process.sleep(200)
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

      Process.sleep(100)

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
          Process.sleep(100)
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
          repo: Portal.Repo,
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

  # Mock functions for Cluster.Strategy callbacks
  def mock_connect(_node), do: true
  def mock_disconnect(_node), do: true
  def mock_list_nodes, do: []
  def mock_connect_failing(_node), do: false

  # Mock repo module that returns invalid config
  defmodule InvalidRepo do
    def config do
      [hostname: "invalid.host.that.does.not.exist", port: 9999, connect_timeout: 100]
    end
  end
end
