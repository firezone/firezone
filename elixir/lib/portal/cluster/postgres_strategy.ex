defmodule Portal.Cluster.PostgresStrategy do
  @moduledoc """
  A libcluster strategy that uses PostgreSQL LISTEN/NOTIFY for node discovery.

  Inspired by [libcluster_postgres](https://github.com/supabase/libcluster_postgres),
  this strategy adds proper node disconnect handling and graceful shutdown support.

  ## Features

  - Heartbeat-based discovery via PostgreSQL NOTIFY
  - Automatic disconnect after missed heartbeats
  - Graceful shutdown broadcasts goodbye for immediate disconnect
  - Cloud-agnostic: works anywhere you have PostgreSQL

  ## Configuration

  Environment variables:

      ERLANG_CLUSTER_ADAPTER=Elixir.Portal.Cluster.PostgresStrategy
      ERLANG_CLUSTER_ADAPTER_CONFIG='{"repo":"Portal.Repo","channel_name":"cluster","heartbeat_interval":5000,"missed_heartbeats":3,"node_count":12}'

  Or via Elixir config:

      config :libcluster,
        topologies: [
          default: [
            strategy: Portal.Cluster.PostgresStrategy,
            config: [
              repo: Portal.Repo,
              channel_name: "cluster",
              heartbeat_interval: 5_000,
              missed_heartbeats: 3,
              node_count: 3
            ]
          ]
        ]

  ## Options

  - `:repo` - (required) Ecto Repo module for database config
  - `:channel_name` - PostgreSQL channel name. Defaults to "cluster"
  - `:heartbeat_interval` - Heartbeat interval in ms. Defaults to 5000
  - `:missed_heartbeats` - Missed heartbeats before disconnect. Defaults to 3
  - `:node_count` - Expected node count for threshold-based error logging

  ## Rolling Deploys

  When migrating from another clustering strategy (e.g., `GoogleComputeLabelsStrategy`),
  nodes using different strategies cannot discover each other. To avoid split-brain
  during rolling deploys, configure both strategies to run simultaneously using the
  secondary adapter.

  Example migrating from GoogleComputeLabelsStrategy to PostgresStrategy:

      # Primary: new PostgresStrategy
      ERLANG_CLUSTER_ADAPTER=Elixir.Portal.Cluster.PostgresStrategy
      ERLANG_CLUSTER_ADAPTER_CONFIG='{"repo":"Portal.Repo","node_count":12}'

      # Secondary: existing GoogleComputeLabelsStrategy (keep during transition)
      ERLANG_CLUSTER_ADAPTER_SECONDARY=Elixir.Portal.Cluster.GoogleComputeLabelsStrategy
      ERLANG_CLUSTER_ADAPTER_SECONDARY_CONFIG='{"project_id":"my-project","cluster_name":"firezone","cluster_name_label":"cluster_name","cluster_version_label":"cluster_version","cluster_version":"1_0","node_name_label":"application","polling_interval_ms":10000,"node_count":12,"release_name":"portal"}'

  Both strategies will run in parallel, and nodes discovered by either mechanism
  will be connected. After all nodes are running the new code, remove the secondary
  adapter configuration in a subsequent deploy.
  """

  use GenServer
  use Cluster.Strategy

  require Logger

  @default_channel_name "cluster"
  @default_heartbeat_interval 5_000
  @default_missed_heartbeats 3

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl GenServer
  def init([state]) do
    Process.flag(:trap_exit, true)

    repo = Keyword.fetch!(state.config, :repo)
    channel_name = Keyword.get(state.config, :channel_name, @default_channel_name)

    heartbeat_interval =
      Keyword.get(state.config, :heartbeat_interval, @default_heartbeat_interval)

    missed_heartbeats = Keyword.get(state.config, :missed_heartbeats, @default_missed_heartbeats)

    state =
      state
      |> Map.put(:repo, repo)
      |> Map.put(:channel_name, channel_name)
      |> Map.put(:heartbeat_interval, heartbeat_interval)
      |> Map.put(:missed_heartbeats, missed_heartbeats)
      |> Map.put(:node_timestamps, %{})
      |> Map.put(:connected_nodes, [])
      |> Map.put(:below_threshold?, false)
      |> Map.put(:listener_pid, nil)
      |> Map.put(:notify_conn, nil)

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    case start_connections(state) do
      {:ok, listener_pid, notify_conn} ->
        send(self(), :heartbeat)
        {:noreply, %{state | listener_pid: listener_pid, notify_conn: notify_conn}}

      {:error, reason} ->
        Logger.error("Failed to start PostgreSQL connections", reason: inspect(reason))
        Process.send_after(self(), :retry_connect, state.heartbeat_interval)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:retry_connect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(:heartbeat, state) do
    broadcast_heartbeat(state)
    state = check_stale_nodes(state)

    :telemetry.execute([:portal, :cluster], %{
      discovered_nodes_count: map_size(state.node_timestamps)
    })

    Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    {:noreply, state}
  end

  def handle_info({:notification, _pid, _ref, channel, payload}, state)
      when channel == state.channel_name do
    {:noreply, handle_notification(payload, state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{listener_pid: pid} = state) do
    Logger.warning("PostgreSQL listener died, reconnecting", reason: inspect(reason))
    Process.send_after(self(), :retry_connect, state.heartbeat_interval)
    {:noreply, %{state | listener_pid: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{notify_conn: pid} = state) do
    Logger.warning("PostgreSQL notify connection died, reconnecting", reason: inspect(reason))
    Process.send_after(self(), :retry_connect, state.heartbeat_interval)
    {:noreply, %{state | notify_conn: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    broadcast_goodbye(state)
    :ok
  end

  defp start_connections(state) do
    postgrex_config = build_postgrex_config(state.repo.config())

    # Two connections needed: one for LISTEN (Notifications), one for NOTIFY (regular)
    with {:ok, notify_conn} <- Postgrex.start_link(postgrex_config),
         {:ok, listener} <- Postgrex.Notifications.start_link(postgrex_config),
         {:ok, _ref} <- Postgrex.Notifications.listen(listener, state.channel_name) do
      Process.monitor(notify_conn)
      Process.monitor(listener)
      {:ok, listener, notify_conn}
    end
  end

  defp build_postgrex_config(repo_config) do
    repo_config
    |> Keyword.take([
      :hostname,
      :port,
      :database,
      :username,
      :password,
      :ssl,
      :socket_options,
      :parameters
    ])
    |> Keyword.put_new(:hostname, "localhost")
    |> Keyword.put_new(:port, 5432)
  end

  defp broadcast_heartbeat(state), do: notify(state, "heartbeat:#{node()}")
  defp broadcast_goodbye(state), do: notify(state, "goodbye:#{node()}")

  defp notify(%{notify_conn: nil}, _payload), do: :ok

  defp notify(%{notify_conn: conn, channel_name: channel}, payload) do
    case Postgrex.query(conn, "SELECT pg_notify($1, $2)", [channel, payload]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send cluster notification", reason: inspect(reason))
    end
  catch
    :exit, reason -> Logger.error("Failed to send cluster notification", reason: inspect(reason))
  end

  defp handle_notification("heartbeat:" <> node_name, state) do
    node = String.to_atom(node_name)
    if node == node(), do: state, else: handle_heartbeat(node, state)
  end

  defp handle_notification("goodbye:" <> node_name, state) do
    node = String.to_atom(node_name)
    if node == node(), do: state, else: handle_goodbye(node, state)
  end

  defp handle_notification(_payload, state), do: state

  defp handle_heartbeat(node, state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | node_timestamps: Map.put(state.node_timestamps, node, now)}

    case Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, [node]) do
      :ok ->
        state = %{state | connected_nodes: Enum.uniq([node | state.connected_nodes])}
        maybe_log_threshold_recovery(state)

      {:error, bad_nodes} ->
        problem_nodes = Enum.map(bad_nodes, &elem(&1, 0))

        Logger.info("Error connecting to nodes",
          connected_nodes: inspect(state.connected_nodes),
          problem_nodes: inspect(problem_nodes)
        )

        maybe_log_threshold_error(state, problem_nodes)
    end
  end

  defp handle_goodbye(node, state) do
    Logger.info("Received goodbye from node, disconnecting", node: node)

    state = %{
      state
      | node_timestamps: Map.delete(state.node_timestamps, node),
        connected_nodes: List.delete(state.connected_nodes, node)
    }

    Cluster.Strategy.disconnect_nodes(state.topology, state.disconnect, state.list_nodes, [node])
    maybe_log_threshold_error(state, [node])
  end

  defp check_stale_nodes(state) do
    now = System.monotonic_time(:millisecond)
    stale_threshold = state.heartbeat_interval * state.missed_heartbeats

    {stale_nodes, active_timestamps} =
      Enum.reduce(state.node_timestamps, {[], %{}}, fn {node, last_seen}, {stale, active} ->
        if now - last_seen > stale_threshold do
          {[node | stale], active}
        else
          {stale, Map.put(active, node, last_seen)}
        end
      end)

    if stale_nodes == [] do
      %{state | node_timestamps: active_timestamps}
    else
      Logger.info("Disconnecting stale nodes", nodes: inspect(stale_nodes))

      Cluster.Strategy.disconnect_nodes(
        state.topology,
        state.disconnect,
        state.list_nodes,
        stale_nodes
      )

      state = %{
        state
        | node_timestamps: active_timestamps,
          connected_nodes: state.connected_nodes -- stale_nodes
      }

      maybe_log_threshold_error(state, stale_nodes)
    end
  end

  # Only log when crossing the threshold boundary to avoid log flooding
  defp maybe_log_threshold_error(state, problem_nodes) do
    if enough_nodes_connected?(state) do
      %{state | below_threshold?: false}
    else
      unless state.below_threshold? do
        Logger.error("Connected nodes count is below threshold",
          connected_nodes: inspect(state.connected_nodes),
          problem_nodes: inspect(problem_nodes),
          config: inspect(state.config)
        )
      end

      %{state | below_threshold?: true}
    end
  end

  defp maybe_log_threshold_recovery(state) do
    if enough_nodes_connected?(state) do
      if state.below_threshold? do
        Logger.info("Connected nodes count is back above threshold",
          connected_nodes: inspect(state.connected_nodes),
          config: inspect(state.config)
        )
      end

      %{state | below_threshold?: false}
    else
      state
    end
  end

  defp enough_nodes_connected?(state) do
    case Keyword.fetch(state.config, :node_count) do
      {:ok, expected_node_count} ->
        connected_node_count = [node() | state.connected_nodes] |> Enum.uniq() |> length()
        connected_node_count >= expected_node_count

      :error ->
        true
    end
  end
end
