defmodule Domain.Cache.Client do
  @moduledoc """
    This cache is used in the client channel to maintain a materialized view of the client access state.
    The cache is updated via WAL messages streamed from the Domain.Changes.ReplicationConnection module.

    We use basic data structures and binary representations instead of full Ecto schema structs
    to minimize memory usage. The rough structure of the cache data structure and some napkin math
    on their memory usage (assuming "worst-case" usage scenarios) is described below.

      Data structure:

        %{
          policies: %{id:uuidv4:16 => {
            resource_id:uuidv4:16,
            actor_group_id:uuidv4:16,
            conditions:[%{
              property:atom:0,
              operator:atom:0,
              values:
              [string:varies]:(16 * len)}:(40 - small map)
              ]:(16 * len)
            }:16
          }:(num_keys * 1.8 * 8 - large map)

          resources: %{id:uuidv4:16 => {
            name: string:(~ 1.25 bytes per char),
            address:string:(~ 1.25 bytes per char),
            address_description:string:(~ 1.25 bytes per char),
            ip_stack: atom:0,
            type: atom:0,
            filters: [%{protocol: atom:0, ports: [string:(~ 1.25 bytes per char)]}:(40 - small map)]:(16 * len),
            gateway_groups: [%{
              name:string:(~1.25 bytes per char),
              resource_id:uuidv4:16,
              gateway_group_id:uuidv4:16
            }]
          }},

          memberships: %{group_id:uuidv4:16 => membership_id:uuidv4:16}
        }


      For 1,000 policies, 500 resources, 100 memberships, 100 flows (per connected client):

        513,400 bytes, 280,700 bytes, 24,640 bytes, 24,640 bytes

      = 843,380 bytes
      = ~ 1 MB (per client)

  """

  alias Domain.{Actors, Auth, Clients, Cache, Gateways, Resources, Policies}
  require Logger
  require OpenTelemetry.Tracer
  import Ecto.UUID, only: [dump!: 1, load!: 1]

  defstruct [
    # A map of all the policies that match an actor group we're in.
    :policies,

    # A map of all the resources associated to the policies above.
    :resources,

    # A map of actor group IDs to membership IDs we're in.
    :memberships,

    # The set of all resources we can currently connect to. This is defined as:
    # 1. The resource is authorized based on policies and conditions
    # 2. The resource is compatible with the client (i.e. the client can connect to it)
    # 3. The resource has at least one gateway group associated with it
    :connectable_resource_ids
  ]

  @type t :: %__MODULE__{
          policies: %{Cache.Cacheable.uuid_binary() => Domain.Cache.Cacheable.Policy.t()},
          resources: %{Cache.Cacheable.uuid_binary() => Domain.Cache.Cacheable.Resource.t()},
          memberships: %{Cache.Cacheable.uuid_binary() => Cache.Cacheable.uuid_binary()},
          connectable_resource_ids: MapSet.t(Cache.Cacheable.uuid_binary())
        }

  @doc """
    Authorizes a new flow for the given client and resource or returns a list of violated properties if
    the resource is not authorized for the client.
  """

  @spec authorize_resource(t(), %Clients.Client{}, Ecto.UUID.t(), %Auth.Subject{}) ::
          {:ok, Cache.Cacheable.Policy.t(), non_neg_integer()}
          | {:error, {:forbidden, violated_properties: [atom()]}}

  def authorize_resource(cache, client, resource_id, subject) do
    rid_bytes = dump!(resource_id)

    cache.policies
    |> Enum.filter(fn {_id, policy} -> policy.resource_id == rid_bytes end)
    |> Enum.map(fn {_id, policy} -> policy end)
    |> Policies.longest_conforming_policy_for_client(client, subject.expires_at)
  end

  @doc """
    Recomputes the list of connectable resources, returning the newly connectable resources
    and the IDs of resources that are no longer connectable so that the client may update its
    state. This should be called periodically to handle differences due to time-based policy conditions.
  """

  @spec recompute_connectable_resources(t() | nil, %Clients.Client{}) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def recompute_connectable_resources(nil, client) do
    hydrate(client)
    |> recompute_connectable_resources(client)
  end

  def recompute_connectable_resources(cache, client) do
    previous_ids = cache.connectable_resource_ids

    # Get the list of connectable resources based on policies this client conforms to
    connectable_resources =
      cache.policies
      |> conforming_resource_ids(client)
      |> adapted_resources(cache.resources, client)

    if connectable_resources == [] do
      {:ok, [], Enum.map(previous_ids, &load!/1), cache}
    else
      # We have connectable resources, so we need to update the cache
      connectable_ids = MapSet.new(Enum.map(connectable_resources, & &1.id))

      added_ids = MapSet.difference(connectable_ids, previous_ids)
      removed_ids = MapSet.difference(previous_ids, connectable_ids)

      added_resources =
        Enum.filter(connectable_resources, fn r -> MapSet.member?(added_ids, r.id) end)

      cache = %{cache | connectable_resource_ids: connectable_ids}

      {:ok, added_resources, Enum.map(removed_ids, &load!/1), cache}
    end
  end

  @doc """
    Fetches a membership id by an actor_group_id.
  """

  @spec fetch_membership_id(t(), Cache.Cacheable.uuid_binary()) ::
          {:ok, Ecto.UUID.t()} | {:error, :not_found}

  def fetch_membership_id(cache, gid_bytes) do
    cache.memberships
    |> Map.fetch(gid_bytes)
    |> case do
      {:ok, mid_bytes} -> {:ok, load!(mid_bytes)}
      :error -> {:error, :not_found}
    end
  end

  @doc """
    Fetches an authorized resource by its id from the cache.
  """

  @spec fetch_authorized_resource(t(), Ecto.UUID.t()) ::
          {:ok, Domain.Cache.Cacheable.Resource.t()} | {:error, :not_found}

  def fetch_authorized_resource(cache, resource_id) do
    rid_bytes = dump!(resource_id)

    with true <- MapSet.member?(cache.connectable_resource_ids, rid_bytes),
         {:ok, resource} <- Map.fetch(cache.resources, rid_bytes) do
      {:ok, resource}
    else
      false -> {:error, :not_found}
      :error -> {:error, :not_found}
    end
  end

  @doc """
    Adds a new membership to the cache, potentially fetching the missing policies and resources
    that we don't already have in our cache.

    Since this affects connectable resources, we recompute the connectable resources, which could
    yield deleted IDs, so we send those back.
  """

  @spec add_membership(t(), %Clients.Client{}) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def add_membership(cache, client) do
    # TODO: Optimization
    # For simplicity, we rehydrate the cache here. This could be made more efficient by calculating which
    # policies and resources we are missing, and selectively fetching, filtering, and updating the cache.
    # This is not expected to cause an issue in production since in most cases, bulk new memberships would imply
    # bulk new groups, which shouldn't have much if any policies associated to them.
    previously_connectable_ids = cache.connectable_resource_ids

    # Use the previous connectable IDs so that the recomputation yields the difference
    cache = %{hydrate(client) | connectable_resource_ids: previously_connectable_ids}

    recompute_connectable_resources(cache, client)
  end

  @doc """
    Removes all policies, resources, and memberships associated with the given group_id from the cache.
  """

  @spec delete_membership(t(), %Actors.Membership{}) :: {:ok, [Ecto.UUID.t()], t()}

  def delete_membership(cache, membership) do
    gid_bytes = dump!(membership.group_id)

    rid_bytes_to_remove =
      cache.policies
      |> Enum.filter(fn {_id, p} -> p.actor_group_id == gid_bytes end)
      |> Enum.map(fn {_id, p} -> p.resource_id end)
      |> Enum.uniq()

    updated_policies =
      cache.policies
      |> Enum.reject(fn {_id, p} -> p.actor_group_id == gid_bytes end)
      |> Enum.into(%{})

    updated_resources =
      cache.resources
      |> Map.drop(rid_bytes_to_remove)

    updated_memberships =
      cache.memberships
      |> Map.delete(gid_bytes)

    updated_connectable_ids =
      MapSet.difference(cache.connectable_resource_ids, MapSet.new(rid_bytes_to_remove))

    # Get removed IDs to send client
    removed_ids =
      MapSet.difference(
        cache.connectable_resource_ids,
        updated_connectable_ids
      )
      |> Enum.map(&load!/1)

    cache = %{
      cache
      | policies: updated_policies,
        resources: updated_resources,
        memberships: updated_memberships,
        connectable_resource_ids: updated_connectable_ids
    }

    {:ok, removed_ids, cache}
  end

  @doc """
    Updates any relevant resources in the cache with the new group name.
  """

  @spec update_resources_with_group_name(
          t(),
          %Gateways.Group{},
          %Clients.Client{}
        ) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], t()}

  def update_resources_with_group_name(cache, group, client) do
    group = Domain.Cache.Cacheable.to_cache(group)

    # Get updated resources
    updated_resources =
      cache.resources
      |> Enum.filter(fn {_id, resource} ->
        Enum.any?(resource.gateway_groups, fn gg -> gg.id == group.id end)
      end)
      |> Enum.map(fn {id, resource} ->
        # Replace old group with new
        gateway_groups =
          Enum.map(resource.gateway_groups, fn gg ->
            if gg.id == group.id do
              group
            else
              gg
            end
          end)

        {id, %{resource | gateway_groups: gateway_groups}}
      end)
      |> Enum.into(%{})

    resources = Map.merge(cache.resources, updated_resources)
    cache = %{cache | resources: resources}

    # Get client-compatible updated resources to return
    updated_resources
    |> Map.take(MapSet.to_list(cache.connectable_resource_ids))
    |> Map.values()
    |> Enum.map(fn r -> adapt(r, client) end)
    |> case do
      [] ->
        {:ok, [], cache}

      resources ->
        {:ok, resources, cache}
    end
  end

  @doc """
    Adds a new policy to the cache. If the policy includes a resource we do not already have in the cache,
    we fetch the resource from the database and add it to the cache.

    If the resource is compatible with and authorized for the current client, we return the resource,
    otherwise we just return the updated cache.
  """

  @spec add_policy(t(), %Policies.Policy{}, %Clients.Client{}, %Auth.Subject{}) ::
          {:ok, Domain.Cache.Cacheable.Resource.t(), t()} | {:ok, t()} | {:error, :not_found}

  def add_policy(cache, %{resource_id: resource_id} = policy, client, subject) do
    policy = Domain.Cache.Cacheable.to_cache(policy)

    if Map.has_key?(cache.memberships, policy.actor_group_id) do
      # Add policy to the cache
      cache = %{cache | policies: Map.put(cache.policies, policy.id, policy)}

      # Maybe add resource to the cache if we don't already have it
      cache =
        if Map.has_key?(cache.resources, policy.resource_id) do
          cache
        else
          # Need to fetch the resource from the DB
          opts = [preload: :gateway_groups]
          {:ok, resource} = Resources.fetch_resource_by_id(resource_id, subject, opts)

          resource = Domain.Cache.Cacheable.to_cache(resource)

          %{cache | resources: Map.put(cache.resources, resource.id, resource)}
        end

      # If the resource is already connectable by the client, we just return the updated cache.
      # Otherwise we check if it's connectable and return it if it is.
      if MapSet.member?(cache.connectable_resource_ids, policy.resource_id) do
        {:ok, cache}
      else
        [policy]
        |> conforming_resource_ids(client)
        |> adapted_resources(cache.resources, client)
        |> case do
          [] ->
            {:ok, cache}

          [resource] ->
            connectable_ids = MapSet.put(cache.connectable_resource_ids, resource.id)
            cache = %{cache | connectable_resource_ids: connectable_ids}
            {:ok, resource, cache}
        end
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
    Updates policy in cache with given policy if it exists. Breaking policy changes are handled separately
    with a delete and then add operation.
  """

  @spec update_policy(t(), %Policies.Policy{}) :: {:ok, t()} | {:error, :not_found}

  def update_policy(cache, policy) do
    policy = Domain.Cache.Cacheable.to_cache(policy)

    if Map.has_key?(cache.policies, policy.id) do
      # Update the cache with the new policy
      cache = %{cache | policies: Map.put(cache.policies, policy.id, policy)}
      {:ok, cache}
    else
      # Policy does not exist in the cache, so we return an error
      {:error, :not_found}
    end
  end

  @doc """
    Removes a policy from the cache. If we can't find another policy granting access to the resource,
    we return the deleted resource ID.
  """
  @spec delete_policy(t(), %Policies.Policy{}, %Clients.Client{}) ::
          {:ok, Ecto.UUID.t(), t()} | {:ok, t()} | {:error, :not_found}
  def delete_policy(cache, policy, client) do
    policy = Domain.Cache.Cacheable.to_cache(policy)

    if Map.has_key?(cache.policies, policy.id) do
      # Update the cache
      cache = %{cache | policies: Map.delete(cache.policies, policy.id)}

      # Remove the resource if no policies are left for it
      no_more_policies? =
        cache.policies
        |> Enum.all?(fn {_id, p} -> p.resource_id != policy.resource_id end)

      resources =
        if no_more_policies? do
          Map.delete(cache.resources, policy.resource_id)
        else
          cache.resources
        end

      cache = %{cache | resources: resources}

      connectable_ids = cache.connectable_resource_ids
      conforming_ids = conforming_resource_ids(cache.policies, client) |> MapSet.new()
      difference = MapSet.difference(connectable_ids, conforming_ids)

      case MapSet.to_list(difference) do
        [] ->
          # No change
          {:ok, cache}

        [removed_id] ->
          # Update the connectable resources
          updated_ids = MapSet.delete(connectable_ids, removed_id)
          cache = %{cache | connectable_resource_ids: updated_ids}
          {:ok, load!(removed_id), cache}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
    Adds a gateway group (by virtue of the added resource connection) to the appropriate resource in the cache.

    Since resource connection is a join record, we need to fetch the group from the DB to get its name.

    Since adding a gateway group requires re-evaluating policies, the resource could now be connectable or not connectable
    so we return either the deleted resource ID or the updated resource if there's a change. Otherwise we simply
    return the updated cache.
  """
  @spec add_resource_connection(t(), %Resources.Connection{}, %Auth.Subject{}, %Clients.Client{}) ::
          {:ok, Ecto.UUID.t(), t()}
          | {:ok, Domain.Cache.Cacheable.Resource.t(), t()}
          | {:ok, t()}
          | {:error, :not_found}
  def add_resource_connection(cache, connection, subject, client) do
    rid_bytes = dump!(connection.resource_id)

    if Map.has_key?(cache.resources, rid_bytes) do
      # We need the gateway group to add it
      {:ok, gateway_group} = Gateways.fetch_group_by_id(connection.gateway_group_id, subject)
      gateway_group = Domain.Cache.Cacheable.to_cache(gateway_group)

      # Update the cache - it could contain this resource, but with an empty gateway groups list
      resources =
        cache.resources
        |> Map.update!(rid_bytes, fn resource ->
          if gateway_group in resource.gateway_groups do
            # Duplicates here mean something is amiss, so be noisy about it.
            Logger.error("Duplicate gateway group in resource cache",
              resource: resource,
              gateway_group: gateway_group
            )

            resource
          else
            %{resource | gateway_groups: [gateway_group | resource.gateway_groups]}
          end
        end)

      cache = %{cache | resources: resources}

      resource = Map.get(cache.resources, rid_bytes) |> adapt(client)

      # Determine if this resource is now connectable.
      # If it was connectable before, we simple return the updated resource since adding resource connections
      # should never remove connectability.
      # If it was not connectable before, we first need to check if this resource now conforms to policies and is compatible with the client.
      if MapSet.member?(cache.connectable_resource_ids, rid_bytes) do
        {:ok, resource, cache}
      else
        authorized? =
          case authorize_resource(cache, client, connection.resource_id, subject) do
            {:ok, _expires_at, _policy} -> true
            {:error, _} -> false
          end

        if authorized? and not is_nil(resource) do
          # Add to connectable resources
          connectable_ids = MapSet.put(cache.connectable_resource_ids, rid_bytes)
          cache = %{cache | connectable_resource_ids: connectable_ids}
          {:ok, resource, cache}
        else
          # Not connectable, so we just return the updated cache
          {:ok, cache}
        end
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
    Deletes a gateway group (by virtue of the deleted resource connection) from the appropriate resource in the cache.
    If the resource has no more gateway groups, we return the resource ID so the client can remove it. Otherwise, we
    return the updated resource.
  """

  @spec delete_resource_connection(t(), %Resources.Connection{}, %Clients.Client{}) ::
          {:ok, Ecto.UUID.t(), t()}
          | {:ok, Domain.Cache.Cacheable.Resource.t(), t()}
          | {:ok, t()}
          | {:error, :not_found}

  def delete_resource_connection(cache, connection, client) do
    rid_bytes = dump!(connection.resource_id)

    if Map.has_key?(cache.resources, rid_bytes) do
      # Update the cache
      resources =
        cache.resources
        |> Map.update!(rid_bytes, fn resource ->
          gateway_groups =
            Enum.reject(resource.gateway_groups, fn gg ->
              gg.id == dump!(connection.gateway_group_id)
            end)

          %{resource | gateway_groups: gateway_groups}
        end)

      cache = %{cache | resources: resources}

      cache.resources
      |> Map.take(MapSet.to_list(cache.connectable_resource_ids))
      |> Map.fetch(rid_bytes)
      |> case do
        {:ok, %{gateway_groups: []}} ->
          # No more gateway groups - send deleted id to remove
          connectable_ids = MapSet.delete(cache.connectable_resource_ids, rid_bytes)
          cache = %{cache | connectable_resource_ids: connectable_ids}
          {:ok, load!(rid_bytes), cache}

        {:ok, resource} ->
          # Still has gateway groups, return the adapted, updated resource
          {:ok, adapt(resource, client), cache}

        :error ->
          # Resource is not connectable, so just return the updated cache
          {:ok, cache}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
    Updates a resource in the cache with the given resource if it exists.

    If the resource's address has changed and we are no longer compatible with it, we
    need to remove it from the client's list of resources.

    Otherwise, if the resource's address has changed and we are _now_ compatible with it, we need
    to add it to the client's list of resources.

    If the resource has not meaningfully changed (i.e. the cached versions are the same),
    we return only the updated cache.
  """

  @spec update_resource(t(), %Resources.Resource{}, %Resources.Resource{}, %Clients.Client{}) ::
          {:ok, Ecto.UUID.t(), t()}
          | {:ok, Domain.Cache.Cacheable.Resource.t(), t()}
          | {:ok, t()}
          | {:error, :not_found}

  def update_resource(cache, old_resource, resource, client) do
    old_resource = Domain.Cache.Cacheable.to_cache(old_resource)
    resource = Domain.Cache.Cacheable.to_cache(resource)

    if Map.has_key?(cache.resources, resource.id) do
      # Copy preloaded gateway groups
      resource = %{
        resource
        | gateway_groups: Map.get(cache.resources, resource.id).gateway_groups
      }

      # Update the cache
      resources = %{cache.resources | resource.id => resource}
      cache = %{cache | resources: resources}

      if MapSet.member?(cache.connectable_resource_ids, resource.id) do
        # Check if it's still connectable
        case adapt(resource, client) do
          nil ->
            # Not compatible with the client anymore, so we remove it from the connectable resources
            connectable_ids = MapSet.delete(cache.connectable_resource_ids, resource.id)
            cache = %{cache | connectable_resource_ids: connectable_ids}
            {:ok, load!(resource.id), cache}

          ^old_resource ->
            # Resource is effectively unchanged
            {:ok, cache}

          adapted_resource ->
            {:ok, adapted_resource, cache}
        end
      else
        case adapt(resource, client) do
          nil ->
            # Not compatible with the client, so we just return the updated cache
            {:ok, cache}

          adapted_resource ->
            # Resource is now connectable, so we add it to the connectable resources
            connectable_ids = MapSet.put(cache.connectable_resource_ids, adapted_resource.id)
            cache = %{cache | connectable_resource_ids: connectable_ids}
            {:ok, adapted_resource, cache}
        end
      end
    else
      {:error, :not_found}
    end
  end

  defp hydrate(client) do
    attributes = %{
      actor_id: client.actor_id
    }

    OpenTelemetry.Tracer.with_span "Cache.Cacheable.hydrate", attributes: attributes do
      {_policies, cache} =
        Policies.all_policies_for_actor_id!(client.actor_id)
        |> Enum.map_reduce(%{policies: %{}, resources: %{}}, fn policy, cache ->
          resource = Cache.Cacheable.to_cache(policy.resource)
          resources = Map.put(cache.resources, resource.id, resource)

          policy = Cache.Cacheable.to_cache(policy)
          policies = Map.put(cache.policies, policy.id, policy)

          {policy, %{cache | policies: policies, resources: resources}}
        end)

      memberships =
        Actors.all_memberships_for_actor_id!(client.actor_id)
        |> Enum.map(fn membership ->
          {dump!(membership.group_id), dump!(membership.id)}
        end)
        |> Enum.into(%{})

      cache
      |> Map.put(:memberships, memberships)
      |> Map.put(:connectable_resource_ids, MapSet.new())
    end
  end

  defp adapted_resources(conforming_resource_ids, resources, client) do
    conforming_resource_ids
    |> Enum.map(fn id -> Map.get(resources, id) end)
    |> Enum.map(fn r -> adapt(r, client) end)
    |> Enum.reject(fn r -> is_nil(r) end)
    |> Enum.filter(fn r -> r.gateway_groups != [] end)
  end

  defp conforming_resource_ids(policies, client) when is_map(policies) do
    policies
    |> Map.values()
    |> conforming_resource_ids(client)
  end

  defp conforming_resource_ids(policies, client) do
    policies
    |> Policies.filter_by_conforming_policies_for_client(client)
    |> Enum.map(& &1.resource_id)
    |> Enum.uniq()
  end

  defp adapt(resource, client) do
    Resources.adapt_resource_for_version(resource, client.last_seen_version)
  end
end
