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

  alias Domain.{Cache, Gateways}
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
      all_gateway_flows_for_cache!(gateway)
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
    for {tuple, flow_id_map} <- cache,
        filtered =
          Map.reject(flow_id_map, fn {_fid_bytes, expires_at_unix} ->
            expires_at_unix < now_unix
          end),
        map_size(filtered) > 0,
        into: %{} do
      {tuple, filtered}
    end
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
  @spec reauthorize_deleted_flow(t(), Domain.Flow.t()) ::
          {:ok, non_neg_integer(), t()} | {:error, :unauthorized, t()} | {:error, :not_found}
  def reauthorize_deleted_flow(cache, %Domain.Flow{} = flow) do
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

  defp flow_key(%Domain.Flow{client_id: client_id, resource_id: resource_id}) do
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
    case reauthorize_flow(flow) do
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

  # Inline functions from Domain.Flows

  defp all_gateway_flows_for_cache!(%Domain.Gateway{} = gateway) do
    import Ecto.Query
    
    from(f in Domain.Flow, as: :flows)
    |> where([flows: f], f.account_id == ^gateway.account_id)
    |> where([flows: f], f.gateway_id == ^gateway.id)
    |> Domain.Flow.Query.not_expired()
    |> Domain.Flow.Query.for_cache()
    |> Domain.Safe.unscoped()
    |> Domain.Safe.all()
  end

  defp reauthorize_flow(%Domain.Flow{} = flow) do
    require Logger
    
    with client when not is_nil(client) <- fetch_client_by_id!(flow.client_id),
         {:ok, token} <- fetch_token_by_id(flow.token_id),
         {:ok, gateway} <- fetch_gateway_by_id(flow.gateway_id),
         # We only want to reauthorize the resource for this gateway if the resource is still connected to its
         # site.
         policies when policies != [] <-
           all_policies_in_site_for_resource_id_and_actor_id!(
             flow.account_id,
             gateway.site_id,
             flow.resource_id,
             client.actor_id
           ),
         {:ok, policy, expires_at} <-
           longest_conforming_policy_for_client(policies, client, token, flow.expires_at),
         {:ok, membership} <-
           fetch_membership_by_actor_id_and_group_id(
             client.actor_id,
             policy.actor_group_id
           ),
         {:ok, new_flow} <-
           Domain.Flow.Changeset.create(%{
             token_id: flow.token_id,
             policy_id: policy.id,
             client_id: flow.client_id,
             gateway_id: flow.gateway_id,
             resource_id: flow.resource_id,
             actor_group_membership_id: membership.id,
             account_id: flow.account_id,
             client_remote_ip: client.last_seen_remote_ip,
             client_user_agent: client.last_seen_user_agent,
             gateway_remote_ip: flow.gateway_remote_ip,
             expires_at: expires_at
           })
           |> Domain.Safe.unscoped()
           |> Domain.Safe.insert() do

      Logger.info("Reauthorized flow",
        old_flow: inspect(flow),
        new_flow: inspect(new_flow)
      )

      {:ok, new_flow}
    else
      reason ->
        Logger.info("Failed to reauthorize flow",
          old_flow: inspect(flow),
          reason: inspect(reason)
        )

        :error
    end
  end

  # Database helper functions for reauthorize_flow

  defp fetch_client_by_id!(id, _opts \\ []) do
    import Ecto.Query

    from(c in Domain.Client, as: :clients)
    |> where([clients: c], c.id == ^id)
    |> Domain.Safe.unscoped()
    |> Domain.Safe.one()
  end

  defp fetch_gateway_by_id(id) do
    import Ecto.Query

    result =
      from(g in Domain.Gateway, as: :gateways)
      |> where([gateways: g], g.id == ^id)
      |> Domain.Safe.unscoped()
      |> Domain.Safe.one()

    case result do
      nil -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      gateway -> {:ok, gateway}
    end
  end

  defp fetch_token_by_id(id) do
    import Ecto.Query

    result =
      from(t in Domain.Token,
        where: t.id == ^id,
        where: t.expires_at > ^DateTime.utc_now() or is_nil(t.expires_at)
      )
      |> Domain.Safe.unscoped()
      |> Domain.Safe.one()

    case result do
      nil -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      token -> {:ok, token}
    end
  end

  defp fetch_membership_by_actor_id_and_group_id(actor_id, group_id) do
    import Ecto.Query

    from(m in Domain.Membership,
      where: m.actor_id == ^actor_id,
      where: m.group_id == ^group_id
    )
    |> Domain.Safe.unscoped()
    |> Domain.Safe.one()
    |> case do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  end

  defp all_policies_in_site_for_resource_id_and_actor_id!(
         account_id,
         site_id,
         resource_id,
         actor_id
       ) do
    import Ecto.Query

    from(p in Domain.Policy, as: :policies)
    |> where([policies: p], is_nil(p.disabled_at))
    |> where([policies: p], p.account_id == ^account_id)
    |> where([policies: p], p.resource_id == ^resource_id)
    |> join(:inner, [policies: p], ag in assoc(p, :actor_group), as: :actor_group)
    |> join(:inner, [policies: p], r in assoc(p, :resource), as: :resource)
    |> join(:inner, [resource: r], rc in Domain.Resources.Connection,
      on: rc.resource_id == r.id,
      as: :resource_connections
    )
    |> where([resource_connections: rc], rc.site_id == ^site_id)
    |> join(:inner, [], actor in Domain.Actor, on: actor.id == ^actor_id, as: :actor)
    |> join(:left, [actor_group: ag], m in assoc(ag, :memberships), as: :memberships)
    |> where(
      [memberships: m, actor_group: ag, actor: a],
      m.actor_id == ^actor_id or
        (ag.type == :managed and
           is_nil(ag.idp_id) and
           ag.name == "Everyone" and
           ag.account_id == a.account_id)
    )
    |> preload(resource: :sites)
    |> Domain.Safe.unscoped()
    |> Domain.Safe.all()
  end

  @infinity ~U[9999-12-31 23:59:59.999999Z]

  defp longest_conforming_policy_for_client(policies, client, auth_provider_id, expires_at) do
    policies
    |> Enum.reduce(%{failed: [], succeeded: []}, fn policy, acc ->
      case ensure_client_conforms_policy_conditions(policy, client, auth_provider_id) do
        {:ok, expires_at} ->
          %{acc | succeeded: [{expires_at, policy} | acc.succeeded]}

        {:error, {:forbidden, violated_properties: violated_properties}} ->
          %{acc | failed: acc.failed ++ violated_properties}
      end
    end)
    |> case do
      %{succeeded: [], failed: failed} ->
        {:error, {:forbidden, violated_properties: Enum.uniq(failed)}}

      %{succeeded: succeeded} ->
        {condition_expires_at, policy} =
          succeeded |> Enum.max_by(fn {exp, _policy} -> exp || @infinity end)

        {:ok, policy, min_expires_at(condition_expires_at, expires_at)}
    end
  end

  defp ensure_client_conforms_policy_conditions(
         %Domain.Policy{} = policy,
         %Domain.Client{} = client,
         auth_provider_id
       ) do
    ensure_client_conforms_policy_conditions(
      Domain.Cache.Cacheable.to_cache(policy),
      client,
      auth_provider_id
    )
  end

  defp ensure_client_conforms_policy_conditions(
         %Domain.Cache.Cacheable.Policy{} = policy,
         %Domain.Client{} = client,
         auth_provider_id
       ) do
    case Domain.Policies.Evaluator.ensure_conforms(policy.conditions, client, auth_provider_id) do
      {:ok, expires_at} ->
        {:ok, expires_at}

      {:error, violated_properties} ->
        {:error, {:forbidden, violated_properties: violated_properties}}
    end
  end

  defp min_expires_at(nil, nil),
    do: raise("Both policy_expires_at and token_expires_at cannot be nil")

  defp min_expires_at(nil, token_expires_at), do: token_expires_at

  defp min_expires_at(%DateTime{} = policy_expires_at, %DateTime{} = token_expires_at) do
    if DateTime.compare(policy_expires_at, token_expires_at) == :lt do
      policy_expires_at
    else
      token_expires_at
    end
  end
end
