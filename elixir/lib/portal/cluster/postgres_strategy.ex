defmodule Portal.Cluster.PostgresStrategy do
  @moduledoc """
  A libcluster strategy that uses PostgreSQL LISTEN/NOTIFY for node discovery.

  Inspired by [libcluster_postgres](https://github.com/supabase/libcluster_postgres).
  Every node announces itself with a heartbeat NOTIFY, and every node connects to
  the nodes it hears from. The strategy never disconnects nodes: Erlang distribution
  drops a node when its VM exits, or after `net_ticktime` when it dies without
  closing its connections. Disconnecting a node that is still running, such as one
  draining during a deploy, makes `global` warn about overlapping partitions.

  ## Configuration

  Environment variables:

      ERLANG_CLUSTER_ADAPTER=Elixir.Portal.Cluster.PostgresStrategy
      ERLANG_CLUSTER_ADAPTER_CONFIG='{"repo":"Portal.Repo","channel_name":"cluster","heartbeat_interval":5000,"node_count":12}'

  Or via Elixir config:

      config :libcluster,
        topologies: [
          default: [
            strategy: Portal.Cluster.PostgresStrategy,
            config: [
              repo: Portal.Repo,
              channel_name: "cluster",
              heartbeat_interval: 5_000,
              node_count: 3
            ]
          ]
        ]

  ## Options

  - `:repo` - (required) Ecto Repo module for database config
  - `:channel_name` - PostgreSQL channel name. Defaults to "cluster"
  - `:heartbeat_interval` - Heartbeat interval in ms. Defaults to 5000
  - `:node_count` - Expected node count. An error is logged when fewer nodes stay
    connected for three heartbeats

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
  @threshold_heartbeats 3

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl GenServer
  def init([state]) do
    Process.flag(:trap_exit, true)

    state =
      state
      |> Map.put(:repo, Keyword.fetch!(state.config, :repo))
      |> Map.put(:channel_name, Keyword.get(state.config, :channel_name, @default_channel_name))
      |> Map.put(
        :heartbeat_interval,
        Keyword.get(state.config, :heartbeat_interval, @default_heartbeat_interval)
      )
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
        Logger.error("Failed to start PostgreSQL connections", reason: reason)
        Process.send_after(self(), :retry_connect, state.heartbeat_interval)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:retry_connect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(:heartbeat, state) do
    notify(state, "heartbeat:#{node()}")

    nodes = list_nodes(state)
    :telemetry.execute([:portal, :cluster], %{discovered_nodes_count: length(nodes)})

    Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    {:noreply, check_node_count(state, nodes)}
  end

  def handle_info({:notification, _pid, _ref, channel, "heartbeat:" <> node_name}, state)
      when channel == state.channel_name do
    connect_node(state, node_name)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{listener_pid: pid} = state) do
    Logger.warning("PostgreSQL listener died, reconnecting", reason: reason)
    Process.send_after(self(), :retry_connect, state.heartbeat_interval)
    {:noreply, %{state | listener_pid: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{notify_conn: pid} = state) do
    Logger.warning("PostgreSQL notify connection died, reconnecting", reason: reason)
    Process.send_after(self(), :retry_connect, state.heartbeat_interval)
    {:noreply, %{state | notify_conn: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
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
    # :configure re-resolves the password before each connect attempt, e.g. a
    # fresh Entra token when DATABASE_ENTRA_AUTH is enabled
    repo_config
    |> Keyword.take([
      :hostname,
      :port,
      :database,
      :username,
      :password,
      :ssl,
      :socket_options,
      :parameters,
      :configure
    ])
    |> Keyword.put_new(:hostname, "localhost")
    |> Keyword.put_new(:port, 5432)
  end

  defp notify(%{notify_conn: nil}, _payload), do: :ok

  defp notify(%{notify_conn: conn, channel_name: channel}, payload) do
    case Postgrex.query(conn, "SELECT pg_notify($1, $2)", [channel, payload]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send cluster notification", reason: reason)
    end
  catch
    :exit, reason -> Logger.error("Failed to send cluster notification", reason: reason)
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp connect_node(state, node_name) do
    node = String.to_atom(node_name)

    if node != node() do
      Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, [node])
    end
  end

  defp list_nodes(%{list_nodes: {module, function, args}}), do: apply(module, function, args)

  # Only log after a sustained shortfall, so the brief dip while a deploy replaces
  # nodes stays quiet.
  #
  # below_threshold? states:
  #   false               — at or above threshold
  #   {:pending, mono_ms} — first dropped below threshold at this time, waiting
  #   true                — sustained shortfall confirmed, error already logged
  defp check_node_count(state, nodes) do
    case Keyword.fetch(state.config, :node_count) do
      {:ok, expected} when length(nodes) + 1 < expected -> below_threshold(state, nodes)
      _ -> above_threshold(state, nodes)
    end
  end

  defp below_threshold(%{below_threshold?: false} = state, _nodes) do
    %{state | below_threshold?: {:pending, System.monotonic_time(:millisecond)}}
  end

  defp below_threshold(%{below_threshold?: {:pending, since}} = state, nodes) do
    if System.monotonic_time(:millisecond) - since >= state.heartbeat_interval * @threshold_heartbeats do
      Logger.error("Connected nodes count is below threshold",
        connected_nodes: nodes,
        config: state.config
      )

      %{state | below_threshold?: true}
    else
      state
    end
  end

  defp below_threshold(state, _nodes), do: state

  defp above_threshold(%{below_threshold?: true} = state, nodes) do
    Logger.info("Connected nodes count is back above threshold",
      connected_nodes: nodes,
      config: state.config
    )

    %{state | below_threshold?: false}
  end

  defp above_threshold(state, _nodes), do: %{state | below_threshold?: false}
end
