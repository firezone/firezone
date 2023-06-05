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

  defmodule Meta do
    @type t :: %{
            access_token: String.t(),
            access_token_expires_at: DateTime.t(),
            nodes: MapSet.t()
          }

    defstruct access_token: nil,
              access_token_expires_at: nil,
              nodes: nil
  end

  @default_polling_interval 5_000

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{} = state]) do
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
    {:ok, nodes, state} = fetch_nodes(state)
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
  end

  @doc false
  # We use Google Compute Engine metadata server to fetch the node access token,
  # it will have scopes declared in the instance template but actual permissions
  # are limited by the service account attached to it.
  def refresh_access_token(state) do
    config = fetch_config!()
    token_endpoint_url = Keyword.fetch!(config, :token_endpoint_url)
    request = Finch.build(:get, token_endpoint_url, [{"Metadata-Flavor", "Google"}])

    case Finch.request(request, Domain.Cluster.Finch) do
      {:ok, %Finch.Response{status: 200, body: response}} ->
        %{"access_token" => access_token, "expires_in" => expires_in} = Jason.decode!(response)
        access_token_expires_at = DateTime.utc_now() |> DateTime.add(expires_in - 1, :second)

        {:ok,
         %{
           state
           | meta: %{
               state.meta
               | access_token: access_token,
                 access_token_expires_at: access_token_expires_at
             }
         }}

      {:ok, response} ->
        Cluster.Logger.warn(:google, "Can not fetch instance metadata: #{inspect(response)}")
        {:error, {response.status, response.body}}

      {:error, reason} ->
        Cluster.Logger.warn(:google, "Can not fetch instance metadata: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_refresh_access_token(state) do
    cond do
      is_nil(state.meta.access_token) ->
        refresh_access_token(state)

      is_nil(state.meta.access_token_expires_at) ->
        refresh_access_token(state)

      DateTime.diff(state.meta.access_token_expires_at, DateTime.utc_now()) > 0 ->
        {:ok, state}

      true ->
        refresh_access_token(state)
    end
  end

  @doc false
  # We use Google Compute API to fetch the list of instances in all regions of a project,
  # instances are filtered by cluster name and status, and then we use this instance labels
  # to figure out the actual node name (which is set in `rel/env.sh.eex` by also reading node metadata).
  def fetch_nodes(state, remaining_retry_count \\ 3) do
    with {:ok, state} <- maybe_refresh_access_token(state),
         {:ok, nodes} <- fetch_google_cloud_instances(state) do
      {:ok, nodes, state}
    else
      {:error, %{"error" => %{"code" => 401}} = reason} ->
        Cluster.Logger.error(
          :google,
          "Invalid access token was used: #{inspect(reason)}"
        )

        if remaining_retry_count == 0 do
          {:error, reason}
        else
          {:ok, state} = refresh_access_token(state)
          fetch_nodes(state, remaining_retry_count - 1)
        end

      {:error, reason} ->
        Cluster.Logger.error(
          :google,
          "Can not fetch list of nodes or access token: #{inspect(reason)}"
        )

        if remaining_retry_count == 0 do
          {:error, reason}
        else
          backoff_interval = Keyword.get(state.config, :backoff_interval, 1_000)
          :timer.sleep(backoff_interval)
          fetch_nodes(state, remaining_retry_count - 1)
        end
    end
  end

  defp fetch_google_cloud_instances(state) do
    project_id = Keyword.fetch!(state.config, :project_id)
    cluster_name = Keyword.fetch!(state.config, :cluster_name)
    cluster_name_label = Keyword.get(state.config, :cluster_name_label, "cluster_name")
    node_name_label = Keyword.get(state.config, :node_name_label, "application")

    aggregated_list_endpoint_url =
      fetch_config!()
      |> Keyword.fetch!(:aggregated_list_endpoint_url)
      |> String.replace("${project_id}", project_id)

    filter = "labels.#{cluster_name_label}=#{cluster_name} AND status=RUNNING"
    query = URI.encode_query(%{"filter" => filter})
    request = Finch.build(:get, aggregated_list_endpoint_url <> "?" <> query)

    with {:ok, %Finch.Response{status: 200, body: response}} <-
           Finch.request(request, Domain.Cluster.Finch),
         {:ok, %{"items" => items}} <- Jason.decode(response) do
      nodes =
        items
        |> Enum.flat_map(fn
          {_zone, %{"instances" => instances}} ->
            instances

          {_zone, %{"warning" => %{"code" => "NO_RESULTS_ON_PAGE"}}} ->
            []
        end)
        |> Enum.filter(fn
          %{"status" => "RUNNING", "labels" => %{^cluster_name_label => ^cluster_name}} -> true
          %{"status" => _status, "labels" => _labels} -> false
        end)
        |> Enum.map(fn %{"zone" => zone, "name" => name, "labels" => labels} ->
          release_name = Map.fetch!(labels, node_name_label)
          zone = String.split(zone, "/") |> List.last()
          node_name = :"#{release_name}@#{name}.#{zone}.c.#{project_id}.internal"
          Cluster.Logger.debug(:gce, "   - Found node: #{inspect(node_name)}")
          node_name
        end)

      {:ok, nodes}
    else
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:ok, map} ->
        {:error, map}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end

  defp polling_interval(%State{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end
end
