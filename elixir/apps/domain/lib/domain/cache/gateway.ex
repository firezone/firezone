defmodule Domain.Cache.Gateway do
  @moduledoc """
    This cache is used in the gateway channel processes to maintain a materialized view of the gateway flow state.
    The cache is updated via WAL messages streamed from the Domain.Changes.ReplicationConnection module.

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

  alias Domain.{Cache, Flows, Gateways}
  import Ecto.UUID, only: [dump!: 1, load!: 1]

  require OpenTelemetry.Tracer

  # Type definitions
  @type client_resource_key ::
          {client_id :: Cache.Cacheable.uuid_binary(),
           resource_id :: Cache.Cacheable.uuid_binary()}
  @type flow_map :: %{
          (flow_id :: Cache.Cacheable.uuid_binary()) => expires_at_unix :: non_neg_integer
        }
  @type t :: %{client_resource_key() => flow_map()}

  @doc """
    Fetches relevant flows from the DB and transforms them into the cache format.
  """
  @spec hydrate(Gateways.Gateway.t()) :: t()
  def hydrate(gateway) do
    OpenTelemetry.Tracer.with_span "Domain.Cache.hydrate_flows",
      attributes: %{
        gateway_id: gateway.id,
        account_id: gateway.account_id
      } do
      Flows.all_gateway_flows_for_cache!(gateway)
      |> Enum.reduce(%{}, fn {{client_id, resource_id}, {flow_id, expires_at}}, acc ->
        cid_bytes = dump!(client_id)
        rid_bytes = dump!(resource_id)
        fid_bytes = dump!(flow_id)
        expires_at_unix = DateTime.to_unix(expires_at, :second)

        flow_id_map = Map.get(acc, {cid_bytes, rid_bytes}, %{})

        Map.put(acc, {cid_bytes, rid_bytes}, Map.put(flow_id_map, fid_bytes, expires_at_unix))
      end)
    end
  end

  @doc """
    Removes expired flows from the cache.
  """
  @spec prune(t()) :: t()
  def prune(cache) do
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
  @spec get(t(), Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer() | nil
  def get(cache, client_id, resource_id) do
    tuple = {dump!(client_id), dump!(resource_id)}

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
  @spec put(t(), Ecto.UUID.t(), Cache.Cacheable.uuid_binary(), Ecto.UUID.t(), DateTime.t()) :: t()
  def put(%{} = cache, client_id, rid_bytes, flow_id, %DateTime{} = expires_at) do
    tuple = {dump!(client_id), rid_bytes}

    flow_id_map =
      Map.get(cache, tuple, %{})
      |> Map.put(dump!(flow_id), DateTime.to_unix(expires_at, :second))

    Map.put(cache, tuple, flow_id_map)
  end

  @doc """
    Delete a flow from the cache. If another flow exists for the same client/resource,
    we return the max expiration for that resource.
    If not, we optimistically try to reauthorize access by creating a new flow. This prevents
    removal of access on the Gateway but not the client, which would cause connectivity issues.
    If we can't create a new authorization, we send unauthorized so that access is removed.
  """
  @spec reauthorize_deleted_flow(t(), Flows.Flow.t()) ::
          {:ok, non_neg_integer(), t()} | {:error, :unauthorized, t()} | {:error, :not_found}
  def reauthorize_deleted_flow(cache, %Flows.Flow{} = flow) do
    key = flow_key(flow)
    flow_id = dump!(flow.id)

    case get_and_remove_flow(cache, key, flow_id) do
      {:not_found, _cache} ->
        {:error, :not_found}

      {:last_flow_removed, cache} ->
        handle_last_flow_removal(cache, key, flow)

      {:flow_removed, remaining_flows, cache} ->
        max_expiration = remaining_flows |> Map.values() |> Enum.max()
        {:ok, max_expiration, cache}
    end
  end

  defp flow_key(%Flows.Flow{client_id: client_id, resource_id: resource_id}) do
    {dump!(client_id), dump!(resource_id)}
  end

  defp get_and_remove_flow(cache, key, flow_id) do
    case Map.fetch(cache, key) do
      :error ->
        {:not_found, cache}

      {:ok, flow_map} ->
        case Map.pop(flow_map, flow_id) do
          {nil, _} ->
            {:not_found, cache}

          {_expiration, remaining_flows} when remaining_flows == %{} ->
            {:last_flow_removed, Map.delete(cache, key)}

          {_expiration, remaining_flows} ->
            {:flow_removed, remaining_flows, Map.put(cache, key, remaining_flows)}
        end
    end
  end

  defp handle_last_flow_removal(cache, key, flow) do
    case Flows.reauthorize_flow(flow) do
      {:ok, new_flow} ->
        new_flow_id = dump!(new_flow.id)
        expires_at_unix = DateTime.to_unix(new_flow.expires_at, :second)
        new_flow_map = %{new_flow_id => expires_at_unix}

        {:ok, expires_at_unix, Map.put(cache, key, new_flow_map)}

      :error ->
        {:error, :unauthorized, cache}
    end
  end

  @doc """
    Check if the cache has a resource entry for the given resource_id.
    Returns true if the resource is present, false otherwise.
  """
  @spec has_resource?(t(), Ecto.UUID.t()) :: boolean()
  def has_resource?(%{} = cache, resource_id) do
    rid_bytes = dump!(resource_id)

    cache
    |> Map.keys()
    |> Enum.any?(fn {_, rid} ->
      rid == rid_bytes
    end)
  end

  @doc """
    Return a list of all pairs matching the resource ID.
  """
  @spec all_pairs_for_resource(t(), Ecto.UUID.t()) :: [{Ecto.UUID.t(), Ecto.UUID.t()}]
  def all_pairs_for_resource(%{} = cache, resource_id) do
    rid_bytes = dump!(resource_id)

    cache
    |> Enum.filter(fn {{_, rid}, _} -> rid == rid_bytes end)
    |> Enum.map(fn {{cid, _}, _} -> {load!(cid), resource_id} end)
  end
end
