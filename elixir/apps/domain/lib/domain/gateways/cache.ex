defmodule Domain.Gateways.Cache do
  @moduledoc """
    This cache is used in the gateway channel processes to maintain a materialized view of the gateway flow state.
    The cache is updated via WAL messages streamed from the Domain.Events.ReplicationConnection module.

    We use basic data structures and binary representations instead of full Ecto schema structs
    to minimize memory usage. The rough structure of the two cached data structures and some napkin math
    on their memory usage (assuming "worst-case" usage scenarios) is described below.

    Data structure:

      %{{client_id:uuidv4:16, resource_id:uuidv4:16}:16 => %{flow_id:uuidv4:16 => expires_at:integer:8}:40}:(num_keys * 1.8 * 8 - large map)

    For 10,000 client/resource entries, consisting of 10 flows each:

      10,000 keys, 100,000 values
      480,000 bytes (outer map keys), 6,400,000 bytes (inner map), 144,000 bytes (outer map overhead)

    = 7,024,000
    = ~ 7 MB
  """

  alias Domain.{Flows, Gateways}

  require OpenTelemetry.Tracer

  @doc """
    Fetches relevant flows from the DB and transforms them into the cache format.
  """
  def hydrate(%Gateways.Gateway{} = gateway) do
    OpenTelemetry.Tracer.with_span "Domain.Cache.hydrate_flows",
      attributes: %{
        gateway_id: gateway.id,
        account_id: gateway.account_id
      } do
      Flows.all_gateway_flows_for_cache!(gateway)
      |> Enum.reduce(%{}, fn {{client_id, resource_id}, {flow_id, expires_at}}, acc ->
        cid_bytes = Ecto.UUID.dump!(client_id)
        rid_bytes = Ecto.UUID.dump!(resource_id)
        fid_bytes = Ecto.UUID.dump!(flow_id)
        expires_at_unix = DateTime.to_unix(expires_at, :second)

        flow_id_map = Map.get(acc, {cid_bytes, rid_bytes}, %{})

        Map.put(acc, {cid_bytes, rid_bytes}, Map.put(flow_id_map, fid_bytes, expires_at_unix))
      end)
    end
  end

  def prune(cache) when is_map(cache) do
    now_unix = DateTime.utc_now() |> DateTime.to_unix(:second)

    # 1. Remove individual flows older than 14 days, then remove access entry if no flows left
    cache
    |> Enum.map(fn {tuple, flow_id_map} ->
      flow_id_map =
        Enum.reject(flow_id_map, fn {_fid_bytes, expires_at_unix} ->
          expires_at_unix < now_unix
        end)
        |> Enum.into(%{})

      {tuple, flow_id_map}
    end)
    |> Enum.into(%{})
    |> Enum.reject(fn {_tuple, flow_id_map} -> map_size(flow_id_map) == 0 end)
    |> Enum.into(%{})
  end

  @doc """
    Fetches the max expiration for a client-resource from the cache, or nil if not found.
  """
  def get(%{} = cache, client_id, resource_id) do
    tuple = {Ecto.UUID.dump!(client_id), Ecto.UUID.dump!(resource_id)}

    case Map.get(cache, tuple) do
      nil ->
        nil

      flow_id_map ->
        # Use longest expiration to minimize unnecessary access churn
        flow_id_map
        |> Map.values()
        |> Enum.max()
    end
  end

  @doc """
    Add a flow to the cache. Returns the updated cache.
  """
  def put(%{} = cache, client_id, resource_id, flow_id, %DateTime{} = expires_at) do
    tuple = {Ecto.UUID.dump!(client_id), Ecto.UUID.dump!(resource_id)}

    flow_id_map =
      Map.get(cache, tuple, %{})
      |> Map.put(Ecto.UUID.dump!(flow_id), DateTime.to_unix(expires_at, :second))

    Map.put(cache, tuple, flow_id_map)
  end

  @doc """
    Delete a flow from the cache.
  """
  def delete(%{} = cache, %Flows.Flow{client_id: client_id, resource_id: resource_id} = flow) do
    tuple = {Ecto.UUID.dump!(client_id), Ecto.UUID.dump!(resource_id)}

    if flow_map = Map.get(cache, tuple) do
      flow_id_map = Map.delete(flow_map, Ecto.UUID.dump!(flow.id))

      if map_size(flow_id_map) == 0 do
        Map.delete(cache, tuple)
      else
        Map.put(cache, tuple, flow_id_map)
      end
    else
      cache
    end
  end

  @doc """
    Check if the cache has a resource entry for the given resource_id.
    Returns true if the resource is present, false otherwise.
  """
  def has_resource?(%{} = cache, resource_id) do
    rid_bytes = Ecto.UUID.dump!(resource_id)

    cache
    |> Map.keys()
    |> Enum.any?(fn {_, rid} ->
      rid == rid_bytes
    end)
  end

  @doc """
    Rehydrate the cache with a new flow if access is still allowed.
  """
  def rehydrate(
        %{} = cache,
        %Flows.Flow{client_id: client_id, resource_id: resource_id} = flow
      ) do
    tuple = {Ecto.UUID.dump!(client_id), Ecto.UUID.dump!(resource_id)}

    if Map.has_key?(cache, tuple) do
      cache
    else
      case Flows.reauthorize_flow(flow) do
        {:ok, new_flow} ->
          flow_id_map = %{
            Ecto.UUID.dump!(new_flow.id) => DateTime.to_unix(new_flow.expires_at, :second)
          }

          Map.put(cache, tuple, flow_id_map)

        {:error, _reason} ->
          cache
      end
    end
  end
end
