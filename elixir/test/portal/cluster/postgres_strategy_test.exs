defmodule Portal.Cluster.PostgresStrategyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Portal.Test.Assertions

  alias Portal.Cluster.PostgresStrategy

  describe "heartbeats via LISTEN/NOTIFY" do
    test "broadcasts a heartbeat on startup" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      listener = start_supervised!({Postgrex.Notifications, Portal.Repo.config()})
      {:ok, _ref} = Postgrex.Notifications.listen(listener, channel_name)

      # Use a short heartbeat_interval so connection retries happen quickly
      # in case of transient too_many_connections errors under concurrent test load.
      start_supervised!(
        {PostgresStrategy, [build_state(channel_name: channel_name, heartbeat_interval: 100)]}
      )

      assert_receive {:notification, _, _, ^channel_name, "heartbeat:" <> _}, 5000
    end
  end

  describe "handle_info/2" do
    test ":heartbeat emits the connected node count and schedules the next heartbeat" do
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

      start_supervised!(
        {PostgresStrategy,
         [
           build_state(
             channel_name: channel_name,
             heartbeat_interval: 50,
             list_nodes: [:a@node, :b@node]
           )
         ]}
      )

      assert_receive {:telemetry, %{discovered_nodes_count: 2}}, 1000
      assert_receive {:telemetry, %{discovered_nodes_count: 2}}, 1000

      :telemetry.detach("test-handler-#{channel_name}")
    end

    test "connects to nodes it hears a heartbeat from" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:other@node"})
      sync(pid)

      assert_received {:connected, :other@node}
    end

    test "ignores its own heartbeat" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

      send(pid, {:notification, self(), make_ref(), channel_name, "heartbeat:#{node()}"})
      sync(pid)

      refute_received {:connected, _}
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

    test "never disconnects nodes, even ones that stop sending heartbeats" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name, list_nodes: [:other@node])

      send(pid, {:notification, self(), make_ref(), channel_name, "goodbye:other@node"})
      for _ <- 1..5, do: send(pid, :heartbeat)
      sync(pid)

      refute_received {:disconnected, _}
    end

    test "handles unknown notifications gracefully" do
      channel_name = "test_#{System.unique_integer([:positive])}"

      pid = start_strategy(channel_name: channel_name)

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

  describe "threshold logging" do
    test "does not log on the first heartbeat below the threshold" do
      pid = start_strategy(node_count: 5)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      refute log =~ "Connected nodes count is below threshold"
      assert match?({:pending, _}, :sys.get_state(pid).below_threshold?)
    end

    test "logs error after a sustained shortfall" do
      pid = start_strategy(node_count: 5, list_nodes: [:node1@test])

      :sys.replace_state(pid, fn state ->
        %{state | below_threshold?: {:pending, System.monotonic_time(:millisecond) - :timer.minutes(10)}}
      end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      assert log =~ "Connected nodes count is below threshold"
      assert :sys.get_state(pid).below_threshold? == true
    end

    test "logs recovery once enough nodes are connected again" do
      pid = start_strategy(node_count: 2, list_nodes: [:node1@test])
      :sys.replace_state(pid, fn state -> %{state | below_threshold?: true} end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      assert log =~ "Connected nodes count is back above threshold"
      assert :sys.get_state(pid).below_threshold? == false
    end

    test "does not log recovery from the pending state" do
      pid = start_strategy(node_count: 2, list_nodes: [:node1@test])

      :sys.replace_state(pid, fn state ->
        %{state | below_threshold?: {:pending, System.monotonic_time(:millisecond)}}
      end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      refute log =~ "Connected nodes count is back above threshold"
      assert :sys.get_state(pid).below_threshold? == false
    end

    test "does not log recovery while still below the threshold" do
      pid = start_strategy(node_count: 10, list_nodes: [:node1@test, :node2@test])
      :sys.replace_state(pid, fn state -> %{state | below_threshold?: true} end)

      log =
        capture_log(fn ->
          send(pid, :heartbeat)
          sync(pid)
          Logger.flush()
        end)

      refute log =~ "Connected nodes count is back above threshold"
      assert :sys.get_state(pid).below_threshold? == true
    end
  end

  # Helpers

  defp build_state(opts) do
    connect_fn = Keyword.get(opts, :connect_fn, :mock_connect)

    %{
      topology: :test_topology,
      connect: {__MODULE__, connect_fn, [self()]},
      disconnect: {__MODULE__, :mock_disconnect, [self()]},
      list_nodes: {__MODULE__, :mock_list_nodes, [Keyword.get(opts, :list_nodes, [])]},
      config:
        [
          repo: Keyword.get(opts, :repo, Portal.Repo),
          channel_name: Keyword.get(opts, :channel_name, "test_cluster"),
          heartbeat_interval: Keyword.get(opts, :heartbeat_interval, 60_000),
          node_count: Keyword.get(opts, :node_count, nil)
        ]
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
    }
  end

  defp build_state_with_invalid_repo do
    %{
      topology: :test_topology,
      connect: {__MODULE__, :mock_connect, [self()]},
      disconnect: {__MODULE__, :mock_disconnect, [self()]},
      list_nodes: {__MODULE__, :mock_list_nodes, [[]]},
      config: [
        repo: __MODULE__.InvalidRepo,
        channel_name: "test_cluster",
        heartbeat_interval: 100
      ]
    }
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

  # Forces a synchronous round-trip through the GenServer so prior async
  # messages are handled before the test continues.
  defp sync(pid), do: :sys.get_state(pid)

  # Mock functions for Cluster.Strategy callbacks
  def mock_connect(test_pid, node) do
    send(test_pid, {:connected, node})
    true
  end

  def mock_list_nodes(nodes), do: nodes

  def mock_disconnect(test_pid, node) do
    send(test_pid, {:disconnected, node})
    true
  end
  def mock_connect_failing(_test_pid, _node), do: false

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
