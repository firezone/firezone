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

  defstruct [:policies, :resources, :memberships, :authorized_resource_ids]

  # Type definitions
  @type t :: %__MODULE__{
          policies: %{Cache.Cacheable.uuid_binary() => Domain.Cache.Cacheable.Policy.t()},
          resources: %{Cache.Cacheable.uuid_binary() => Domain.Cache.Cacheable.Resource.t()},
          memberships: %{Cache.Cacheable.uuid_binary() => Cache.Cacheable.uuid_binary()},
          authorized_resource_ids: MapSet.t(Cache.Cacheable.uuid_binary())
        }

  @doc """
    Returns the new cache and full list of currently authorized resources for the given client.
    It's important we avoid hitting the DB here because this function is called often to determine
    what resources the client "sees", and is called when forming a new connection to the gateway.
  """
  @spec authorized_resources(t() | nil, %Clients.Client{}) ::
          {t(), [Domain.Cache.Cacheable.Resource.t()]}

  def authorized_resources(nil, %Clients.Client{} = client) do
    authorized_resources(hydrate(client.actor_id), client)
  end

  def authorized_resources(cache, %Clients.Client{} = client) do
    resource_ids =
      cache.policies
      |> Map.values()
      |> Policies.filter_by_conforming_policies_for_client(client)
      |> Enum.map(& &1.resource_id)
      |> Enum.uniq()

    resources =
      cache.resources
      |> Map.take(resource_ids)
      |> Map.values()
      |> Resources.adapt_resources_for_version(client.last_seen_version)

    # Cache the most recent list of authorized resource IDs for invalidating later
    cache = %{cache | authorized_resource_ids: MapSet.new(Enum.map(resources, & &1.id))}

    {cache, resources}
  end

  @doc """
    Authorizes a new flow for the given client and resource or returns a list of violated properties if
    the resource is not authorized for the client.
  """
  @spec authorize_resource(t(), %Clients.Client{}, Ecto.UUID.t(), %Auth.Subject{}) ::
          {:ok, Cache.Cacheable.Policy.t(), non_neg_integer()}
          | {:error, {:forbidden, violated_properties: [atom()]}}
  def authorize_resource(cache, %Clients.Client{} = client, resource_id, subject) do
    rid_bytes = Ecto.UUID.dump!(resource_id)

    cache.policies
    |> Enum.filter(fn {_id, policy} -> policy.resource_id == rid_bytes end)
    |> Enum.map(fn {_id, policy} -> policy end)
    |> Enum.reduce_while({:error, []}, fn policy, {:error, acc} ->
      case Policies.ensure_client_conforms_policy_conditions(client, policy) do
        {:ok, expires_at} ->
          {:halt, {:ok, policy, expires_at}}

        {:error, {:forbidden, violated_properties: violated_properties}} ->
          {:cont, {:error, violated_properties ++ acc}}
      end
    end)
    |> case do
      {:error, violated_properties} ->
        {:error, {:forbidden, violated_properties: violated_properties}}

      {:ok, policy, expires_at} ->
        # Set a maximum expiration time for the authorization
        expires_at =
          expires_at || subject.expires_at ||
            DateTime.utc_now() |> DateTime.add(14, :day)

        {:ok, policy, expires_at}
    end
  end

  @doc """
    Recomputes the list of authorized resources, invoking the callback with the diff since the
    last authorized_resources call. Used to update the client with any authorization changes
    that can occur without a prior change message, such as a time-based policy condition.
  """
  @spec recompute_authorized_resources(
          t(),
          %Clients.Client{},
          ([Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()] -> any())
        ) :: t()
  def recompute_authorized_resources(cache, %Clients.Client{} = client, callback) do
    # Get the old authorized ids
    old_authorized_ids = cache.authorized_resource_ids

    # Get the current authorized resources
    {cache, _resources} = authorized_resources(cache, client)

    # Get the removed resource IDs
    removed_ids = MapSet.difference(old_authorized_ids, cache.authorized_resource_ids)

    # Get the new authorized resource IDs
    added_ids = MapSet.difference(cache.authorized_resource_ids, old_authorized_ids)

    added_resources =
      cache.resources
      |> Map.take(Enum.to_list(added_ids))
      |> Map.values()

    # Call the callback with the added resources and removed IDs
    callback.(added_resources, Enum.map(removed_ids, &Ecto.UUID.load!/1))

    cache
  end

  @doc """
    Fetches a membership id by an actor_group_id.
  """
  @spec fetch_membership_id(t(), Cache.Cacheable.uuid_binary()) :: {:ok, Ecto.UUID.t()} | :error
  def fetch_membership_id(cache, gid_bytes) do
    cache.memberships
    |> Map.fetch(gid_bytes)
    |> case do
      {:ok, mid_bytes} -> {:ok, Ecto.UUID.load!(mid_bytes)}
      error -> error
    end
  end

  @doc """
    Fetches a resource by its id from the cache.
  """
  @spec fetch_resource(t(), Ecto.UUID.t()) :: {:ok, Domain.Cache.Cacheable.Resource.t()} | :error
  def fetch_resource(cache, resource_id) do
    rid_bytes = Ecto.UUID.dump!(resource_id)

    cache.resources
    |> Map.fetch(rid_bytes)
  end

  @doc """
    Adds a new membership to the cache, potentially fetching the new resource if we don't already have it.

    Invokes the callback with the newly added resource if it's now in the authorized resource list.
  """

  @spec add_membership(
          t(),
          %Clients.Client{},
          (Domain.Cache.Cacheable.Resource.t() -> any())
        ) :: t()
  def add_membership(cache, client, callback) do
    # Save previous authorized resource IDs
    old_authorized_ids = cache.authorized_resource_ids

    # TODO: Optimization
    # This could be improved to pass the existing policies we have, and only return *new* policies
    # that we now have access to, instead of rehyrdating the entire cache. Unfortunately we have
    # to go to the DB in some capacity because this new membership could have added new policies and
    # resources we don't have in the cache yet.
    cache = hydrate(client.actor_id)

    # Get the new authorized resources
    {cache, resources} = authorized_resources(cache, client)

    # Invoke callback with any new resources that were added
    for rid_bytes <- Enum.map(resources, & &1.id) do
      unless MapSet.member?(old_authorized_ids, rid_bytes) do
        callback.(Map.get(cache.resources, rid_bytes))
      end
    end

    cache
  end

  @doc """
    Removes all policies, resources, and memberships associated with the given group_id from the cache.

    Invokes the callback function with the deleted resource_ids.
  """
  @spec delete_membership(t(), %Clients.Client{}, %Actors.Membership{}, ([Ecto.UUID.t()] -> any())) ::
          t()
  def delete_membership(cache, client, membership, callback) do
    gid_bytes = Ecto.UUID.dump!(membership.group_id)

    old_authorized_ids = cache.authorized_resource_ids

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

    cache = %{
      cache
      | policies: updated_policies,
        resources: updated_resources,
        memberships: updated_memberships
    }

    {cache, _resources} = authorized_resources(cache, client)

    # Get the removed resource IDs
    removed_ids =
      MapSet.difference(old_authorized_ids, cache.authorized_resource_ids)
      |> Enum.map(&Ecto.UUID.load!/1)

    # Call the callback with the removed resource IDs
    callback.(removed_ids)

    cache
  end

  @doc """
    Determines the diff of authorized resources given an updated client. Most policy conditions are
    scoped to the client's websocket connection, and so sending a diff mid-connection is not necessary.
    The exception to this is during client verification status updates.

    Invokes the callback with the added resources and removed resources ids.
  """
  @spec update_client(t(), %Clients.Client{}, ([Domain.Cache.Cacheable.Resource.t()],
                                               [Ecto.UUID.t()] ->
                                                 any())) ::
          t()
  def update_client(cache, %Clients.Client{} = client, callback) do
    # Save previous authorized resource IDs
    old_authorized_ids = cache.authorized_resource_ids

    # Get the current authorized resources
    {cache, _resources} = authorized_resources(cache, client)

    # Get the removed resource IDs
    removed_ids = MapSet.difference(old_authorized_ids, cache.authorized_resource_ids)

    # Get the new authorized resource IDs
    added_ids = MapSet.difference(cache.authorized_resource_ids, old_authorized_ids)

    added_resources =
      cache.resources
      |> Map.take(Enum.to_list(added_ids))
      |> Map.values()

    # Call the callback with the added resources and removed IDs
    callback.(added_resources, Enum.map(removed_ids, &Ecto.UUID.load!/1))

    cache
  end

  @doc """
      Determines if any authorized, cached resources need to be updated with the group name.
      If so, calls the provided callback function with all of the updated resources.
  """
  @spec update_resources_with_group_name(
          t(),
          %Gateways.Group{},
          %Gateways.Group{},
          ([Domain.Cache.Cacheable.Resource.t()] -> any())
        ) :: t()
  def update_resources_with_group_name(cache, old_group, group, callback) do
    gid_bytes = Ecto.UUID.dump!(group.id)

    # Update resources
    resources =
      cache.resources
      |> Enum.map(fn {id, resource} ->
        gateway_groups =
          resource.gateway_groups
          |> Enum.map(fn gg ->
            if gg.id == gid_bytes do
              Map.merge(gg, Cache.Cacheable.to_cache(group))
            else
              gg
            end
          end)

        {id, %{resource | gateway_groups: gateway_groups}}
      end)
      |> Enum.into(%{})

    cache = %{cache | resources: resources}

    # Update the client's list with any resources that have the new group name
    Enum.map(cache.authorized_resource_ids, fn rid_bytes ->
      Map.get(cache.resources, rid_bytes)
    end)
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
          %Auth.Subject{},
          (Domain.Cache.Cacheable.Resource.t() -> any())
        ) :: t()
  def add_policy(cache, %{resource_id: resource_id} = policy, client, subject, callback) do
    policy = Domain.Cache.Cacheable.to_cache(policy)

    if Map.has_key?(cache.memberships, policy.actor_group_id) do
      # Snapshot existing authorized ids
      old_authorized_ids = cache.authorized_resource_ids

      # Track added policy
      cache = %{cache | policies: Map.put(cache.policies, policy.id, policy)}

      # Maybe track added resource
      cache =
        if Map.has_key?(cache.resources, policy.resource_id) do
          cache
        else
          {:ok, resource} =
            Resources.fetch_resource_by_id(resource_id, subject, preload: :gateway_groups)

          resource = Domain.Cache.Cacheable.to_cache(resource)
          %{cache | resources: Map.put(cache.resources, resource.id, resource)}
        end

      # Get new authorized resources
      {cache, _resources} = authorized_resources(cache, client)

      added_ids = MapSet.difference(cache.authorized_resource_ids, old_authorized_ids)

      # Maybe send the new resource to the client
      for rid_bytes <- added_ids do
        callback.(Map.get(cache.resources, rid_bytes))
      end

      cache
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
    policy = Domain.Cache.Cacheable.to_cache(policy)

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
  @spec delete_policy(
          t(),
          %Policies.Policy{},
          (Cache.Cacheable.uuid_binary() -> any())
        ) :: t()
  def delete_policy(cache, policy, callback) do
    policy = Domain.Cache.Cacheable.to_cache(policy)

    if Map.has_key?(cache.policies, policy.id) do
      # Snapshot old authorized ids
      old_authorized_ids = cache.authorized_resource_ids

      # Remove the policy
      cache = %{cache | policies: Map.delete(cache.policies, policy.id)}

      # Remove the resource if no policies are left for it
      cache =
        if Map.has_key?(cache.resources, policy.resource_id) and
             Enum.all?(cache.policies, fn {_id, p} -> p.resource_id != policy.resource_id end) do

          %{
            cache
            | resources: Map.delete(cache.resources, policy.resource_id),
              authorized_resource_ids:
                MapSet.delete(cache.authorized_resource_ids, policy.resource_id)
          }
        else
          cache
        end

      # Get removed authorized ids
      removed_ids = MapSet.difference(old_authorized_ids, cache.authorized_resource_ids)

      # Maybe send the removed resource IDs to the client
      Enum.map(removed_ids, &Ecto.UUID.load!/1)
      |> callback.()

      cache
    else
      # Doesn't affect us
      cache
    end
  end

  @doc """
    Adds a gateway group (by virtue of the added resource connection) to the appropriate resource in the cache.

    Since resource connection is a join record, we need to fetch the group from the DB to get its name.

    For each resource in the client's list of authorized resources this affects, we invoke the callback
    with the updated resource.
  """
  @spec add_resource_connection(
          t(),
          %Resources.Connection{},
          %Clients.Client{},
          %Auth.Subject{},
          (Domain.Cache.Cacheable.Resource.t() -> any())
        ) :: t()
  def add_resource_connection(cache, connection, client, subject, callback) do
    rid_bytes = Ecto.UUID.dump!(connection.resource_id)

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
      {cache, authorized_resources} = authorized_resources(cache, client)

      # Maybe call callback with the updated resource
      for resource <- authorized_resources do
        if resource.id == rid_bytes do
          callback.(resource)
        end
      end

      cache
    else
      cache
    end
  end

  @doc """
    Deletes a gateway group (by virtue of the deleted resource connection) from the appropriate resource in the cache.

    For each resource in the client's list of authorized resources this affects, we invoke the callback with the updated
    resource.
  """
  @spec delete_resource_connection(
          t(),
          %Resources.Connection{},
          %Clients.Client{},
          (Domain.Cache.Cacheable.Resource.t() -> any())
        ) :: t()
  def delete_resource_connection(cache, connection, client, callback) do
    rid_bytes = Ecto.UUID.dump!(connection.resource_id)

    if Map.has_key?(cache.resources, rid_bytes) do
      old_authorized_ids = cache.authorized_resource_ids

      # Update the cache
      resources =
        cache.resources
        |> Map.update!(rid_bytes, fn resource ->
          gateway_groups =
            Enum.reject(resource.gateway_groups, fn gg ->
              gg.id == Ecto.UUID.dump!(connection.gateway_group_id)
            end)

          %{resource | gateway_groups: gateway_groups}
        end)

      cache = %{cache | resources: resources}
      {cache, _resources} = authorized_resources(cache, client)

      removed_ids = MapSet.difference(old_authorized_ids, cache.authorized_resource_ids)

      # Maybe call callback with the updated resource
      for removed_id <- removed_ids do
        callback.(Ecto.UUID.load!(removed_id))
      end

      cache
    else
      cache
    end
  end

  @doc """
    Updates a resource in the cache with the given resource if it exists. If the resource is authorized for the client
    and there was a meaningful change, we call the callback with the updated resource.
  """
  @spec update_resource(
          t(),
          %Resources.Resource{},
          %Resources.Resource{},
          %Clients.Client{},
          (Domain.Cache.Cacheable.Resource.t() -> any())
        ) :: t()
  def update_resource(cache, old_resource, resource, client, callback) do
    # Populate preloaded gateway groups
    old_resource = Domain.Cache.Cacheable.to_cache(old_resource)
    resource = Domain.Cache.Cacheable.to_cache(resource)

    if Map.has_key?(cache.resources, resource.id) do
      # Restore preloaded gateway groups - changes to these will be handled by
      # that respective change handler
      resource = %{
        resource
        | gateway_groups: Map.get(cache.resources, resource.id).gateway_groups
      }

      # Update the cache
      cache = %{cache | resources: Map.put(cache.resources, resource.id, resource)}
      {cache, authorized_resources} = authorized_resources(cache, client)

      # Maybe call callback with the updated resource if it's meaningfully changed
      if old_resource != resource do
        for r <- authorized_resources do
          if r.id == resource.id do
            callback.(r)
          end
        end
      end

      cache
    else
      cache
    end
  end

  defp hydrate(actor_id) do
    attributes = %{
      actor_id: actor_id
    }

    OpenTelemetry.Tracer.with_span "Cache.Cacheable.hydrate", attributes: attributes do
      {_policies, cache} =
        Policies.all_policies_for_actor_id!(actor_id)
        |> Enum.map_reduce(%{policies: %{}, resources: %{}}, fn policy, cache ->
          resource = Cache.Cacheable.to_cache(policy.resource)
          resources = Map.put(cache.resources, resource.id, resource)

          policy = Cache.Cacheable.to_cache(policy)
          policies = Map.put(cache.policies, policy.id, policy)

          {policy, Map.merge(cache, %{policies: policies, resources: resources})}
        end)

      memberships =
        Actors.all_memberships_for_actor_id!(actor_id)
        |> Enum.map(fn membership ->
          {Ecto.UUID.dump!(membership.group_id), Ecto.UUID.dump!(membership.id)}
        end)
        |> Enum.into(%{})

      cache
      |> Map.put(:memberships, memberships)
      |> Map.put(:authorized_resource_ids, MapSet.new())
    end
  end
end
