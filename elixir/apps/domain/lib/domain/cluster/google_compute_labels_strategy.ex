defmodule Domain.Cluster.GoogleComputeLabelsStrategy do
  @moduledoc """
  This module implements libcluster strategy for Google Compute Engine, which uses
  Compute API to fetch list of instances in a project by a `cluster_name` label
  and then joins them into an Erlang Cluster using their internal IP addresses.

  In order to work properly, few prerequisites must be met:

  1. Compute API must be enabled for the project;

  2. Instance must have access to Compute API (either by having `compute-ro` or `compute-rw` scope),
  and service account must have a role which grants `compute.instances.list` and `compute.zones.list`
  permissions;

  3. Instances must have a `cluster_name` label with the same value for all instances in a cluster,
  and a valid `application` which can be used as Erlang node name.
  """
  use GenServer
  use Cluster.Strategy
  alias Cluster.Strategy.State
  require Logger

  defmodule Meta do
    @type t :: %{
            nodes: MapSet.t()
          }

    defstruct nodes: MapSet.new()
  end

  @default_polling_interval :timer.seconds(10)

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{} = state]) do
    unless Domain.GoogleCloudPlatform.enabled?(),
      do: "Google Cloud Platform clustering strategy requires GoogleCloudPlatform to be enabled"

    {:ok, %{state | meta: %Meta{}}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    {:noreply, load(state)}
  end

  @impl true
  def handle_info(:timeout, state) do
    handle_info(:load, state)
  end

  def handle_info(:load, %State{} = state) do
    {:noreply, load(state)}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp load(%State{topology: topology, meta: %Meta{} = meta} = state) do
    with {:ok, nodes, state} <- fetch_nodes(state) do
      new_nodes = MapSet.new(nodes)
      added_nodes = MapSet.difference(new_nodes, meta.nodes)
      removed_nodes = MapSet.difference(state.meta.nodes, new_nodes)

      new_nodes =
        case Cluster.Strategy.disconnect_nodes(
               topology,
               state.disconnect,
               state.list_nodes,
               MapSet.to_list(removed_nodes)
             ) do
          :ok ->
            new_nodes

          {:error, bad_nodes} ->
            # Add back the nodes which should have been removed_nodes, but which couldn't be for some reason
            Enum.reduce(bad_nodes, new_nodes, fn {n, _}, acc ->
              MapSet.put(acc, n)
            end)
        end

      new_nodes =
        case Cluster.Strategy.connect_nodes(
               topology,
               state.connect,
               state.list_nodes,
               MapSet.to_list(added_nodes)
             ) do
          :ok ->
            new_nodes

          {:error, bad_nodes} ->
            # Remove the nodes which should have been added_nodes, but couldn't be for some reason
            Enum.reduce(bad_nodes, new_nodes, fn {n, _}, acc ->
              MapSet.delete(acc, n)
            end)
        end

      Process.send_after(self(), :load, polling_interval(state))

      %State{state | meta: %{state.meta | nodes: new_nodes}}
    else
      {:error, reason} ->
        Logger.error("Can't fetch list of nodes: #{inspect(reason)}",
          module: __MODULE__
        )

        state
    end
  end

  @doc false
  # We use Google Compute API to fetch the list of instances in all regions of a project,
  # instances are filtered by cluster name and status, and then we use this instance labels
  # to figure out the actual node name (which is set in `rel/env.sh.eex` by also reading node metadata).
  def fetch_nodes(state, remaining_retry_count \\ 10) do
    with {:ok, nodes} <- list_google_cloud_cluster_nodes(state) do
      {:ok, nodes, state}
    else
      {:error, %{"error" => %{"code" => 401}} = reason} ->
        Logger.error("Invalid access token was used: #{inspect(reason)}",
          module: __MODULE__
        )

        if remaining_retry_count == 0 do
          {:error, reason}
        else
          fetch_nodes(state, remaining_retry_count - 1)
        end

      {:error, reason} ->
        if remaining_retry_count == 0 do
          Logger.error("Can't fetch list of nodes or access token",
            reason: inspect(reason),
            module: __MODULE__
          )

          {:error, reason}
        else
          Logger.info("Can't fetch list of nodes or access token",
            reason: inspect(reason),
            module: __MODULE__
          )

          backoff_interval = Keyword.get(state.config, :backoff_interval, 1_000)
          :timer.sleep(backoff_interval)
          fetch_nodes(state, remaining_retry_count - 1)
        end
    end
  end

  defp list_google_cloud_cluster_nodes(state) do
    project_id = Keyword.fetch!(state.config, :project_id)
    cluster_name = Keyword.fetch!(state.config, :cluster_name)
    cluster_version = Keyword.fetch!(state.config, :cluster_version)
    cluster_name_label = Keyword.get(state.config, :cluster_name_label, "cluster_name")
    cluster_version_label = Keyword.get(state.config, :cluster_version_label, "cluster_version")
    node_name_label = Keyword.get(state.config, :node_name_label, "application")

    with {:ok, instances} <-
           Domain.GoogleCloudPlatform.list_google_cloud_instances_by_labels(
             project_id,
             %{
               cluster_name_label => cluster_name,
               cluster_version_label => cluster_version
             }
           ) do
      nodes =
        instances
        |> Enum.map(fn %{"zone" => zone, "name" => name, "labels" => labels} ->
          release_name = Map.fetch!(labels, node_name_label)
          zone = String.split(zone, "/") |> List.last()
          node_name = :"#{release_name}@#{name}.#{zone}.c.#{project_id}.internal"

          node_name
        end)

      count = length(nodes)

      :telemetry.execute([:domain, :cluster], %{
        discovered_nodes_count: count
      })

      Logger.debug("Found #{count} nodes", module: __MODULE__, nodes: Enum.join(nodes, ", "))

      {:ok, nodes}
    end
  end

  defp polling_interval(%State{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end
end
