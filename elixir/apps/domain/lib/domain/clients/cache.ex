defmodule Domain.Clients.Cache do
  @moduledoc """
    This cache is used in the client channel to maintain a materialized view of the client access state.
    The cache is updated via WAL messages streamed from the Domain.Changes.ReplicationConnection module.

    We use basic data structures and binary representations instead of full Ecto schema structs
    to minimize memory usage. The rough structure of the two cached data structures and some napkin math
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

  alias Domain.{Actors, Clients, Clients.Cacheable, Gateways, Resources, Policies}

  require OpenTelemetry.Tracer

  defstruct [:policies, :resources, :memberships]

  # Type definitions
  @type uuid_binary :: <<_::128>>
  @type t :: %__MODULE__{
          policies: %{uuid_binary() => Domain.Clients.Cache.Policy.t()},
          resources: %{uuid_binary() => Domain.Clients.Cache.Resource.t()},
          memberships: %{uuid_binary() => uuid_binary()}
        }

  @doc """
    Fetches relevant policies, resources, and memberships from the DB and transforms them into the cache format.
    This is used to hydrate the cache when a client connects.
  """
  @spec hydrate(%Actors.Actor{}) :: t()
  def hydrate(actor) do
    attributes = %{
      actor_id: actor.id,
      account_id: actor.account_id
    }

    OpenTelemetry.Tracer.with_span "Clients.Cache.hydrate", attributes: attributes do
      {_policies, cache} =
        Policies.all_policies_for_actor!(actor)
        |> Enum.map_reduce(%{policies: %{}, resources: %{}}, fn policy, cache ->
          resource = Clients.Cacheable.to_cache(policy.resource)
          resources = Map.put(cache.resources, resource.id, resource)

          policy = Clients.Cacheable.to_cache(policy)
          policies = Map.put(cache.policies, policy.id, policy)

          {policy, Map.merge(cache, %{policies: policies, resources: resources})}
        end)

      memberships =
        Actors.all_memberships_for_actor!(actor)
        |> Enum.map(fn membership ->
          {Ecto.UUID.dump!(membership.group_id), Ecto.UUID.dump!(membership.id)}
        end)
        |> Enum.into(%{})

      Map.put(cache, :memberships, memberships)
    end
  end

  @spec authorized_resources(t(), %Clients.Client{}) :: [Domain.Clients.Cache.Resource.t()]
  def authorized_resources(%{} = cache, %Clients.Client{} = client) do
    resource_ids =
      cache.policies
      |> Map.values()
      |> Policies.filter_by_conforming_policies_for_client(client)
      |> Enum.map(& &1.resource_id)
      |> Enum.uniq()

    cache.resources
    |> Map.take(resource_ids)
    |> Map.values()
    |> Resources.adapt_resources_for_version(client.last_seen_version)
  end

  @doc """
    Removes all policies, resources, and memberships associated with the given group_id from the cache.

    Returns {cache, deleted_resource_ids}
  """
  @spec remove_access_for_group_id(t(), Ecto.UUID.t()) :: {t(), [uuid_binary()]}
  def remove_access_for_group_id(cache, group_id) do
    gid_bytes = Ecto.UUID.dump!(group_id)

    rid_bytes_to_remove =
      cache.policies
      |> Enum.filter(fn {_id, policy} -> policy.actor_group_id == gid_bytes end)
      |> Enum.map(fn {_id, policy} -> policy.resource_id end)
      |> Enum.uniq()

    updated_policies =
      cache.policies
      |> Enum.reject(fn {_id, policy} -> policy.actor_group_id == gid_bytes end)
      |> Enum.into(%{})

    updated_resources =
      cache.resources
      |> Map.drop(rid_bytes_to_remove)

    updated_memberships =
      cache.memberships
      |> Map.delete(gid_bytes)

    updated_cache = %{
      cache
      | policies: updated_policies,
        resources: updated_resources,
        memberships: updated_memberships
    }

    {updated_cache, rid_bytes_to_remove}
  end

  @doc """
      Determines if any authorized, cached resources need to be updated with the group name.
      If so, calls the provided callback function with all of the updated resources.
  """
  @spec update_resources_with_group_name(
          t(),
          %Clients.Client{},
          %Gateways.Group{},
          %Gateways.Group{},
          (Domain.Clients.Cache.Resource.t() -> any())
        ) :: t()
  def update_resources_with_group_name(cache, client, old_group, group, callback) do
    gid_bytes = Ecto.UUID.dump!(group.id)

    # Update resources
    resources =
      cache.resources
      |> Enum.map(fn {id, resource} ->
        gateway_groups =
          resource.gateway_groups
          |> Enum.map(fn gg ->
            if gg.id == gid_bytes do
              Map.merge(gg, Cacheable.to_cache(group))
            else
              gg
            end
          end)

        {id, %{resource | gateway_groups: gateway_groups}}
      end)
      |> Enum.into(%{})

    cache = %{cache | resources: resources}

    # Update the client's list with any resources that have the new group name
    authorized_resources(cache, client)
    |> Enum.filter(fn resource ->
      Enum.any?(resource.gateway_groups, fn gg ->
        gg.id == gid_bytes and gg.name != old_group.name
      end)
    end)
    |> callback.()

    cache
  end

  @doc """
    Adds a new policy to the cache. If the policy grants additional access to resources that the client does not already have,
    we call the callback with the new resource.
  """
  @spec add_policy(
          t(),
          %Policies.Policy{},
          %Clients.Client{},
          (Domain.Clients.Cache.Resource.t() -> any())
        ) :: t()
  def add_policy(cache, %{resource_id: resource_id} = policy, client, callback) do
    policy = Domain.Clients.Cacheable.to_cache(policy)

    if Map.has_key?(cache.memberships, policy.actor_group_id) do
      # Snapshot existing resources
      existing_authorized_resources = authorized_resources(cache, client)

      # Track added policy
      cache = %{cache | policies: Map.put(cache.policies, policy.id, policy)}

      # Maybe track added resource
      cache =
        if Map.has_key?(cache.resources, policy.resource_id) do
          cache
        else
          {:ok, resource} = Resources.fetch_resource_for_cache(resource_id)
          resource = Domain.Clients.Cacheable.to_cache(resource)
          %{cache | resources: Map.put(cache.resources, resource.id, resource)}
        end

      # Get new authorized resources
      new_authorized_resources = authorized_resources(cache, client)

      # Maybe send the new resource to the client
      for resource <- new_authorized_resources -- existing_authorized_resources do
        callback.(resource)
      end
    else
      # Doesn't affect us
      cache
    end
  end

  @doc """
    Updates policy in cache with given policy if it exists.
  """
  @spec update_policy(t(), %Policies.Policy{}) :: t()
  def update_policy(cache, policy) do
    policy = Domain.Clients.Cacheable.to_cache(policy)

    if Map.has_key?(cache.policies, policy.id) do
      %{cache | policies: Map.put(cache.policies, policy.id, policy)}
    else
      cache
    end
  end

  @doc """
    Removes a policy from the cache. If the policy removal results in resources being removed from the cache,
    we call the callback with the removed resource IDs.
  """
  @spec remove_policy(
          t(),
          %Policies.Policy{},
          %Clients.Client{},
          (uuid_binary() -> any())
        ) :: t()
  def delete_policy(cache, policy, client, callback) do
    policy = Domain.Clients.Cacheable.to_cache(policy)

    if Map.has_key?(cache.policies, policy.id) do
      # Snapshot existing resources
      existing_authorized_resources = authorized_resources(cache, client)

      # Remove the policy
      cache = %{cache | policies: Map.delete(cache.policies, policy.id)}

      # Remove the resource if no policies are left for it
      cache =
        if Map.has_key?(cache.resources, policy.resource_id) and
             Enum.all?(cache.policies, fn {_id, p} -> p.resource_id != policy.resource_id end) do
          %{cache | resources: Map.delete(cache.resources, policy.resource_id)}
        else
          cache
        end

      # Get new authorized resources
      new_authorized_resources = authorized_resources(cache, client)

      # Maybe send the removed resource IDs to the client
      for resource <- existing_authorized_resources -- new_authorized_resources do
        callback.(resource.id)
      end

      cache
    else
      # Doesn't affect us
      cache
    end
  end
end
