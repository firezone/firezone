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

          memberships: %{group_id:uuidv4:16 => membership_id:uuidv4:16},

          connectable_resources: [Cache.Cacheable.Resource.t()]
        }


      For 1,000 policies, 500 resources, 100 memberships, 100 flows (per connected client):

        513,400 bytes, 280,700 bytes, 24,640 bytes, 24,640 bytes

      = 843,380 bytes
      = ~ 1 MB (per client)

  """

  alias Domain.{Actors, Auth, Clients, Cache, Gateways, Resources, Policies, Version}
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

    # The list resources the client can currently connect to. This is defined as:
    # 1. The resource is authorized based on policies and conditions
    # 2. The resource is compatible with the client (i.e. the client can connect to it)
    # 3. The resource has at least one gateway group associated with it
    :connectable_resources
  ]

  @type t :: %__MODULE__{
          policies: %{Cache.Cacheable.uuid_binary() => Domain.Cache.Cacheable.Policy.t()},
          resources: %{Cache.Cacheable.uuid_binary() => Domain.Cache.Cacheable.Resource.t()},
          memberships: %{Cache.Cacheable.uuid_binary() => Cache.Cacheable.uuid_binary()},
          connectable_resources: [Cache.Cacheable.Resource.t()]
        }

  @doc """
    Authorizes a new flow for the given client and resource or returns a list of violated properties if
    the resource is not authorized for the client.
  """

  @spec authorize_resource(t(), Clients.Client.t(), Ecto.UUID.t(), Auth.Subject.t()) ::
          {:ok, Cache.Cacheable.Resource.t(), Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer()}
          | {:error, :not_found}
          | {:error, {:forbidden, violated_properties: [atom()]}}

  def authorize_resource(cache, client, resource_id, subject) do
    rid_bytes = dump!(resource_id)

    resource = Enum.find(cache.connectable_resources, :not_found, fn r -> r.id == rid_bytes end)

    policy =
      for({_id, %{resource_id: ^rid_bytes} = p} <- cache.policies, do: p)
      |> Policies.longest_conforming_policy_for_client(
        client,
        subject.auth_provider_id,
        subject.expires_at
      )

    with %Cache.Cacheable.Resource{} <- resource,
         {:ok, policy, expires_at} <- policy,
         {:ok, mid_bytes} <- Map.fetch(cache.memberships, policy.actor_group_id) do
      membership_id = load!(mid_bytes)
      policy_id = load!(policy.id)
      {:ok, resource, membership_id, policy_id, expires_at}
    else
      :not_found ->
        Logger.warning("resource not found in connectable resources",
          connectable_resources: inspect(cache.connectable_resources),
          subject: inspect(subject),
          client: inspect(client),
          resource_id: resource_id
        )

        {:error, :not_found}

      :error ->
        Logger.warning("membership not found in cache",
          memberships: inspect(cache.memberships),
          subject: inspect(subject),
          client: inspect(client),
          resource_id: resource_id
        )

        {:error, :not_found}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:error, {:forbidden, violated_properties: violated_properties}}
    end
  end

  @doc """
    Recomputes the list of connectable resources, returning the newly connectable resources
    and the IDs of resources that are no longer connectable so that the client may update its
    state. This should be called periodically to handle differences due to time-based policy conditions.

    If opts[:toggle] is set to true, we ensure that all added resources also have
  """

  @spec recompute_connectable_resources(
          t() | nil,
          Clients.Client.t(),
          Auth.Subject.t(),
          Keyword.t()
        ) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def recompute_connectable_resources(nil, client, subject) do
    hydrate(client)
    |> recompute_connectable_resources(client, subject)
  end

  def recompute_connectable_resources(cache, client, subject, opts \\ []) do
    {toggle, _opts} = Keyword.pop(opts, :toggle, false)

    connectable_resources =
      cache.policies
      |> conforming_resource_ids(client, subject.auth_provider_id)
      |> adapted_resources(cache.resources, client)

    added = connectable_resources -- cache.connectable_resources

    added_ids = Enum.map(added, & &1.id)

    # connlib can handle all resource attribute changes except for changing sites (on older clients),
    # so we can omit the deleted IDs of added resources since they'll be updated gracefully.
    removed_ids =
      for r <- cache.connectable_resources -- connectable_resources,
          toggle or r.id not in added_ids do
        load!(r.id)
      end

    cache = %{cache | connectable_resources: connectable_resources}

    {:ok, added, removed_ids, cache}
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
    Adds a new membership to the cache, potentially fetching the missing policies and resources
    that we don't already have in our cache.

    Since this affects connectable resources, we recompute the connectable resources, which could
    yield deleted IDs, so we send those back.
  """

  @spec add_membership(t(), Clients.Client.t(), Auth.Subject.t()) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def add_membership(cache, client, subject) do
    # TODO: Optimization
    # For simplicity, we rehydrate the cache here. This could be made more efficient by calculating which
    # policies and resources we are missing, and selectively fetching, filtering, and updating the cache.
    # This is not expected to cause an issue in production since in most cases, bulk new memberships would imply
    # bulk new groups, which shouldn't have much if any policies associated to them.
    previously_connectable = cache.connectable_resources

    # Use the previous connectable IDs so that the recomputation yields the difference
    cache = %{hydrate(client) | connectable_resources: previously_connectable}

    recompute_connectable_resources(cache, client, subject)
  end

  @doc """
    Removes all policies, resources, and memberships associated with the given group_id from the cache.
  """

  @spec delete_membership(t(), Actors.Membership.t(), Clients.Client.t(), Auth.Subject.t()) ::
          {:ok, [Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def delete_membership(cache, membership, client, subject) do
    gid_bytes = dump!(membership.group_id)

    updated_policies =
      for {id, p} <- cache.policies, p.actor_group_id != gid_bytes, do: {id, p}, into: %{}

    # Only remove resources that have no remaining policies
    remaining_resource_ids =
      for {_id, p} <- updated_policies, do: p.resource_id, into: MapSet.new()

    updated_resources =
      for {rid_bytes, resource} <- cache.resources,
          MapSet.member?(remaining_resource_ids, rid_bytes),
          do: {rid_bytes, resource},
          into: %{}

    updated_memberships =
      cache.memberships
      |> Map.delete(gid_bytes)

    cache = %{
      cache
      | policies: updated_policies,
        resources: updated_resources,
        memberships: updated_memberships
    }

    recompute_connectable_resources(cache, client, subject)
  end

  @doc """
    Updates any relevant resources in the cache with the new group name.
  """

  @spec update_resources_with_group_name(
          t(),
          Gateways.Group.t(),
          Clients.Client.t(),
          Auth.Subject.t()
        ) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def update_resources_with_group_name(cache, group, client, subject) do
    group = Domain.Cache.Cacheable.to_cache(group)

    # Get updated resources
    resources =
      for {id, resource} <- cache.resources, into: %{} do
        gateway_groups =
          for gg <- resource.gateway_groups do
            if gg.id == group.id, do: group, else: gg
          end

        {id, %{resource | gateway_groups: gateway_groups}}
      end

    cache = %{cache | resources: resources}

    toggle = Version.resource_cannot_change_sites_on_client?(client)

    # For these updates we need to make sure the resource is toggled deleted then created.
    # See https://github.com/firezone/firezone/issues/9881
    recompute_connectable_resources(cache, client, subject, toggle: toggle)
  end

  @doc """
    Adds a new policy to the cache. If the policy includes a resource we do not already have in the cache,
    we fetch the resource from the database and add it to the cache.

    If the resource is compatible with and authorized for the current client, we return the resource,
    otherwise we just return the updated cache.
  """

  @spec add_policy(t(), Policies.Policy.t(), Clients.Client.t(), Auth.Subject.t()) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

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
          {:ok, resource} = Resources.fetch_resource_by_id(resource_id, subject)
          resource = Domain.Repo.preload(resource, :gateway_groups)

          resource = Domain.Cache.Cacheable.to_cache(resource)

          %{cache | resources: Map.put(cache.resources, resource.id, resource)}
        end

      recompute_connectable_resources(cache, client, subject)
    else
      {:ok, [], [], cache}
    end
  end

  @doc """
    Updates policy in cache with given policy if it exists. Breaking policy changes are handled separately
    with a delete and then add operation.
  """

  @spec update_policy(t(), Policies.Policy.t()) :: {:ok, [], [], t()}

  def update_policy(cache, policy) do
    policy = Domain.Cache.Cacheable.to_cache(policy)
    policies = Map.replace(cache.policies, policy.id, policy)
    {:ok, [], [], %{cache | policies: policies}}
  end

  @doc """
    Removes a policy from the cache. If we can't find another policy granting access to the resource,
    we return the deleted resource ID.
  """
  @spec delete_policy(t(), Policies.Policy.t(), Clients.Client.t(), Auth.Subject.t()) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}
  def delete_policy(cache, policy, client, subject) do
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

      recompute_connectable_resources(cache, client, subject)
    else
      {:ok, [], [], cache}
    end
  end

  @doc """
    Adds a gateway group (by virtue of the added resource connection) to the appropriate resource in the cache.

    Since resource connection is a join record, we need to fetch the group from the DB to get its name.

    Since adding a gateway group requires re-evaluating policies, the resource could now be connectable or not connectable
    so we return either the deleted resource ID or the updated resource if there's a change. Otherwise we simply
    return the updated cache.
  """
  @spec add_resource_connection(
          t(),
          Resources.Connection.t(),
          Clients.Client.t(),
          Auth.Subject.t()
        ) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}
  def add_resource_connection(cache, connection, client, subject) do
    rid_bytes = dump!(connection.resource_id)

    if Map.has_key?(cache.resources, rid_bytes) do
      # We need the gateway group to add it
      {:ok, gateway_group} = Gateways.fetch_group_by_id(connection.gateway_group_id, subject)
      gateway_group = Domain.Cache.Cacheable.to_cache(gateway_group)

      # Update the cache
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

      # For these updates we need to make sure the resource is toggled deleted then created.
      # See https://github.com/firezone/firezone/issues/9881
      recompute_connectable_resources(cache, client, subject, toggle: true)
    else
      {:ok, [], [], cache}
    end
  end

  @doc """
    Deletes a gateway group (by virtue of the deleted resource connection) from the appropriate resource in the cache.
    If the resource has no more gateway groups, we return the resource ID so the client can remove it. Otherwise, we
    return the updated resource.
  """

  @spec delete_resource_connection(
          t(),
          Resources.Connection.t(),
          Clients.Client.t(),
          Auth.Subject.t()
        ) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def delete_resource_connection(cache, connection, client, subject) do
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

      # For these updates we need to make sure the resource is toggled deleted then created.
      # See https://github.com/firezone/firezone/issues/9881
      recompute_connectable_resources(cache, client, subject, toggle: true)
    else
      {:ok, [], [], cache}
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

  @spec update_resource(t(), Resources.Resource.t(), Clients.Client.t(), Auth.Subject.t()) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def update_resource(cache, resource, client, subject) do
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

      recompute_connectable_resources(cache, client, subject)
    else
      {:ok, [], [], cache}
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
        for memberships <- Actors.all_memberships_for_actor_id!(client.actor_id),
            do: {dump!(memberships.group_id), dump!(memberships.id)},
            into: %{}

      cache
      |> Map.put(:memberships, memberships)
      |> Map.put(:connectable_resources, [])
    end
  end

  defp adapted_resources(conforming_resource_ids, resources, client) do
    for id <- conforming_resource_ids,
        adapted_resource = Map.get(resources, id) |> adapt(client),
        not is_nil(adapted_resource),
        adapted_resource.gateway_groups != [] do
      adapted_resource
    end
  end

  defp adapt(resource, client) do
    Resources.adapt_resource_for_version(resource, client.last_seen_version)
  end

  defp conforming_resource_ids(policies, client, auth_provider_id) when is_map(policies) do
    policies
    |> Map.values()
    |> conforming_resource_ids(client, auth_provider_id)
  end

  defp conforming_resource_ids(policies, client, auth_provider_id) do
    policies
    |> Policies.filter_by_conforming_policies_for_client(client, auth_provider_id)
    |> Enum.map(& &1.resource_id)
    |> Enum.uniq()
  end
end
