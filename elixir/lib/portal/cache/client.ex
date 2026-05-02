defmodule Portal.Cache.Client do
  alias __MODULE__.Database

  @moduledoc """
    This cache is used in the client channel to maintain a materialized view of the client access state.
    The cache is updated via WAL messages streamed from the Portal.Changes.ReplicationConnection module.

    We use basic data structures and binary representations instead of full Ecto schema structs
    to minimize memory usage. The rough structure of the cache data structure and some napkin math
    on their memory usage (assuming "worst-case" usage scenarios) is described below.

      Data structure:

        %{
          policies: %{id:uuidv4:16 => {
            resource_id:uuidv4:16,
            group_id:uuidv4:16,
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
            site: %{
              name:string:(~1.25 bytes per char),
              id:uuidv4:16
            } or nil,
            devices: [%{id: uuidv4:16, ipv4: inet, ipv6: inet}] or nil
          }},

          memberships: %{group_id:uuidv4:16 => membership_id:uuidv4:16},

          connectable_resources: [Cache.Cacheable.Resource.t()],

          # For each connectable static_device_pool resource, the set of member device IDs.
          pool_members: %{resource_id:uuidv4:16 => MapSet<device_id:uuidv4:16>},

          # Cached IPs for each device that appears in any connectable pool. Used both
          # to render `addresses` on the pool resource and to authorize client_device_access
          # requests by ipv4 or ipv6.
          device_addresses: %{device_id:uuidv4:16 => {ipv4_tuple_or_nil, ipv6_tuple_or_nil}},

          # IPv4 addresses of clients previously authorized to connect to this client.
          authorized_device_ipv4s: MapSet<ipv4_tuple>
        }


      For 1,000 policies, 500 resources, 100 memberships, 100 policy_authorizations (per connected client):

        513,400 bytes, 280,700 bytes, 24,640 bytes, 24,640 bytes

      = 843,380 bytes
      = ~ 1 MB (per client)

  """

  alias Portal.{Authentication, ClientSession, Cache, Resource, Policy, Version}
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
    # 3. The resource has at least one site associated with it (or, for pools, no site is required)
    :connectable_resources,

    # Map of static_device_pool resource_id => MapSet of member device_ids for every
    # currently connectable pool.
    :pool_members,

    # Map of device_id => {ipv4_tuple_or_nil, ipv6_tuple_or_nil} for every device appearing
    # in any connectable pool.
    :device_addresses,

    # IPv4 addresses of clients previously authorized to connect to this client.
    :authorized_device_ipv4s
  ]

  @type ipv4_tuple :: {byte(), byte(), byte(), byte()}
  @type ipv6_tuple ::
          {char(), char(), char(), char(), char(), char(), char(), char()}
  @type denied_addresses :: {ipv4_tuple(), ipv6_tuple()} | nil
  @type pool_device :: %{
          id: Ecto.UUID.t(),
          ipv4: Postgrex.INET.t(),
          ipv6: Postgrex.INET.t()
        }

  @type t :: %__MODULE__{
          policies: %{Cache.Cacheable.uuid_binary() => Portal.Cache.Cacheable.Policy.t()},
          resources: %{Cache.Cacheable.uuid_binary() => Portal.Cache.Cacheable.Resource.t()},
          memberships: %{Cache.Cacheable.uuid_binary() => Cache.Cacheable.uuid_binary()},
          connectable_resources: [Cache.Cacheable.Resource.t()],
          pool_members: %{
            Cache.Cacheable.uuid_binary() => MapSet.t(Cache.Cacheable.uuid_binary())
          },
          device_addresses: %{
            Cache.Cacheable.uuid_binary() => {ipv4_tuple(), ipv6_tuple()}
          },
          authorized_device_ipv4s: MapSet.t(ipv4_tuple())
        }

  @doc """
    Authorizes a new policy_authorization for the given client and resource or returns a list of violated properties if
    the resource is not authorized for the client.
  """

  @spec authorize_resource(
          t(),
          Portal.Device.t(),
          Portal.ClientSession.t(),
          Ecto.UUID.t(),
          Authentication.Subject.t()
        ) ::
          {:ok, Cache.Cacheable.Resource.t(), Ecto.UUID.t() | nil, Ecto.UUID.t(),
           DateTime.t() | nil}
          | {:error, :not_found}
          | {:error, {:forbidden, violated_properties: [atom()]}}

  def authorize_resource(cache, client, session, resource_id, subject) do
    rid_bytes = dump!(resource_id)

    resource = Enum.find(cache.connectable_resources, :not_found, fn r -> r.id == rid_bytes end)

    policy =
      for({_id, %{resource_id: ^rid_bytes} = p} <- cache.policies, do: p)
      |> longest_conforming_policy_for_client(
        client,
        session,
        subject.credential.auth_provider_id,
        subject.expires_at
      )

    with %Cache.Cacheable.Resource{} <- resource,
         {:ok, policy, expires_at} <- policy,
         {:ok, mid_bytes} <- Map.fetch(cache.memberships, policy.group_id) do
      membership_id = if mid_bytes, do: load!(mid_bytes), else: nil
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
    Returns the device_id of the member of the given connectable pool with the matching IPv4 or
    IPv6 address, or `{:error, :forbidden}` if no such device is in this pool.
  """
  @spec authorize_device_access(
          t(),
          Ecto.UUID.t(),
          {:ipv4, ipv4_tuple()} | {:ipv6, ipv6_tuple()}
        ) ::
          {:ok, Ecto.UUID.t()} | {:error, :forbidden}
  def authorize_device_access(cache, resource_id, {family, target_address})
      when family in [:ipv4, :ipv6] do
    rid_bytes = dump!(resource_id)
    device_set = Map.get(cache.pool_members, rid_bytes, MapSet.new())

    device_set
    |> Enum.find_value(fn did_bytes ->
      case Map.get(cache.device_addresses, did_bytes) do
        {ipv4, _} when family == :ipv4 and ipv4 == target_address ->
          load!(did_bytes)

        {_, ipv6} when family == :ipv6 and ipv6 == target_address ->
          load!(did_bytes)

        _ ->
          nil
      end
    end)
    |> case do
      nil -> {:error, :forbidden}
      device_id -> {:ok, device_id}
    end
  end

  @spec track_authorized_device_ipv4(t(), Postgrex.INET.t()) :: t()
  def track_authorized_device_ipv4(cache, %Postgrex.INET{address: ipv4_tuple}) do
    %{cache | authorized_device_ipv4s: MapSet.put(cache.authorized_device_ipv4s, ipv4_tuple)}
  end

  @doc """
    Recomputes the list of connectable resources, returning the newly connectable resources
    and the IDs of resources that are no longer connectable so that the client may update its
    state. This should be called periodically to handle differences due to time-based policy conditions.

    If opts[:toggle] is set to true, we ensure that all added resources also have
  """

  @spec recompute_connectable_resources(
          t() | nil,
          Portal.Device.t(),
          Portal.ClientSession.t(),
          Authentication.Subject.t(),
          Keyword.t()
        ) ::
          {:ok, [Portal.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def recompute_connectable_resources(nil, client, session, subject) do
    hydrate(client, subject)
    |> recompute_connectable_resources(client, session, subject)
  end

  def recompute_connectable_resources(cache, client, session, subject, opts \\ []) do
    {toggle, _opts} = Keyword.pop(opts, :toggle, false)

    raw_connectable =
      cache.policies
      |> conforming_resource_ids(client, session, subject.credential.auth_provider_id)
      |> adapted_resources(cache.resources, session)

    {pool_members, device_addresses} = load_pool_state(raw_connectable, subject)

    connectable_resources =
      Enum.map(raw_connectable, fn resource ->
        case resource.type do
          :static_device_pool ->
            %{resource | devices: render_pool_devices(resource.id, pool_members, device_addresses)}

          _ ->
            resource
        end
      end)

    added = connectable_resources -- cache.connectable_resources

    added_ids = Enum.map(added, & &1.id)

    # connlib can handle all resource attribute changes except for changing sites (on older clients),
    # so we can omit the deleted IDs of added resources since they'll be updated gracefully.
    removed_ids =
      for r <- cache.connectable_resources -- connectable_resources,
          toggle or r.id not in added_ids do
        load!(r.id)
      end

    cache = %{
      cache
      | connectable_resources: connectable_resources,
        pool_members: pool_members,
        device_addresses: device_addresses
    }

    {:ok, added, removed_ids, cache}
  end

  @doc """
    Adds a new membership to the cache, potentially fetching the missing policies and resources
    that we don't already have in our cache.

    Since this affects connectable resources, we recompute the connectable resources, which could
    yield deleted IDs, so we send those back.
  """

  @spec add_membership(
          t(),
          Portal.Device.t(),
          Portal.ClientSession.t(),
          Authentication.Subject.t()
        ) ::
          {:ok, [Portal.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def add_membership(cache, client, session, subject) do
    # TODO: Optimization
    # For simplicity, we rehydrate the cache here. This could be made more efficient by calculating which
    # policies and resources we are missing, and selectively fetching, filtering, and updating the cache.
    # This is not expected to cause an issue in production since in most cases, bulk new memberships would imply
    # bulk new groups, which shouldn't have much if any policies associated to them.
    previously_connectable = cache.connectable_resources

    # Use the previous connectable IDs so that the recomputation yields the difference
    cache = %{hydrate(client, subject) | connectable_resources: previously_connectable}

    recompute_connectable_resources(cache, client, session, subject)
  end

  @doc """
    Removes all policies, resources, and memberships associated with the given group_id from the cache.
  """

  @spec delete_membership(
          t(),
          Portal.Membership.t(),
          Portal.Device.t(),
          Portal.ClientSession.t(),
          Authentication.Subject.t()
        ) ::
          {:ok, [Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def delete_membership(cache, membership, client, session, subject) do
    gid_bytes = dump!(membership.group_id)

    updated_policies =
      for {id, p} <- cache.policies, p.group_id != gid_bytes, do: {id, p}, into: %{}

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

    recompute_connectable_resources(cache, client, session, subject)
  end

  @doc """
    Updates any relevant resources in the cache with the new site name.
  """

  @spec update_resources_with_site_name(
          t(),
          Portal.Site.t(),
          Portal.Device.t(),
          Portal.ClientSession.t(),
          Authentication.Subject.t()
        ) ::
          {:ok, [Portal.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def update_resources_with_site_name(cache, site, client, session, subject) do
    site = Portal.Cache.Cacheable.to_cache(site)

    # Get updated resources
    resources =
      for {id, resource} <- cache.resources, into: %{} do
        updated_site =
          if resource.site && resource.site.id == site.id do
            site
          else
            resource.site
          end

        {id, %{resource | site: updated_site}}
      end

    cache = %{cache | resources: resources}

    toggle = Version.resource_cannot_change_sites_on_client?(session)

    # For these updates we need to make sure the resource is toggled deleted then created.
    # See https://github.com/firezone/firezone/issues/9881
    recompute_connectable_resources(cache, client, session, subject, toggle: toggle)
  end

  @doc """
    Adds a new policy to the cache. If the policy includes a resource we do not already have in the cache,
    we fetch the resource from the database and add it to the cache.

    If the resource is compatible with and authorized for the current client, we return the resource,
    otherwise we just return the updated cache.
  """

  @spec add_policy(
          t(),
          Policy.t(),
          Portal.Device.t(),
          Portal.ClientSession.t(),
          Authentication.Subject.t()
        ) ::
          {:ok, [Portal.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def add_policy(cache, %{resource_id: resource_id} = policy, client, session, subject) do
    policy = Portal.Cache.Cacheable.to_cache(policy)

    if Map.has_key?(cache.memberships, policy.group_id) do
      # Add policy to the cache
      cache = %{cache | policies: Map.put(cache.policies, policy.id, policy)}

      # Maybe add resource to the cache if we don't already have it
      cache =
        if Map.has_key?(cache.resources, policy.resource_id) do
          cache
        else
          # Need to fetch the resource from the DB
          {:ok, resource} = Database.fetch_resource_by_id(resource_id, subject)
          resource = Database.preload_site(resource)

          resource = Portal.Cache.Cacheable.to_cache(resource)

          %{cache | resources: Map.put(cache.resources, resource.id, resource)}
        end

      recompute_connectable_resources(cache, client, session, subject)
    else
      {:ok, [], [], cache}
    end
  end

  @doc """
    Updates policy in cache with given policy if it exists. Breaking policy changes are handled separately
    with a delete and then add operation.
  """

  @spec update_policy(t(), Policy.t()) :: {:ok, [], [], t()}

  def update_policy(cache, policy) do
    policy = Portal.Cache.Cacheable.to_cache(policy)
    policies = Map.replace(cache.policies, policy.id, policy)
    {:ok, [], [], %{cache | policies: policies}}
  end

  @doc """
    Removes a policy from the cache. If we can't find another policy granting access to the resource,
    we return the deleted resource ID.
  """
  @spec delete_policy(
          t(),
          Policy.t(),
          Portal.Device.t(),
          Portal.ClientSession.t(),
          Authentication.Subject.t()
        ) ::
          {:ok, [Portal.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}
  def delete_policy(cache, policy, client, session, subject) do
    policy = Portal.Cache.Cacheable.to_cache(policy)

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

      recompute_connectable_resources(cache, client, session, subject)
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

  @spec update_resource(
          t(),
          Portal.Resource.t(),
          Portal.Device.t(),
          Portal.ClientSession.t(),
          Authentication.Subject.t()
        ) ::
          {:ok, [Portal.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def update_resource(cache, %Portal.Resource{} = changed_resource, client, session, subject) do
    resource = Portal.Cache.Cacheable.to_cache(changed_resource)

    if Map.has_key?(cache.resources, resource.id) do
      cached_resource = Map.get(cache.resources, resource.id)
      site_id_bytes = if changed_resource.site_id, do: Ecto.UUID.dump!(changed_resource.site_id)

      # Check if we can reuse the cached site or need to fetch from DB.
      # site_id can be nil when site is deleted (ON DELETE SET NULL).
      # cached site can be nil if hydration failed to load it.
      {site, site_changed?} =
        cond do
          is_nil(site_id_bytes) ->
            {nil, not is_nil(cached_resource.site)}

          cached_resource.site && cached_resource.site.id == site_id_bytes ->
            {cached_resource.site, false}

          true ->
            {fetch_site_for_resource(site_id_bytes, subject), not is_nil(cached_resource.site)}
        end

      resource = %{resource | site: site}

      # Update the cache
      resources = %{cache.resources | resource.id => resource}
      cache = %{cache | resources: resources}

      # Determine if we need to toggle the resource (delete then add) based on site change and client version
      toggle = Version.resource_cannot_change_sites_on_client?(session) and site_changed?

      recompute_connectable_resources(cache, client, session, subject, toggle: toggle)
    else
      {:ok, [], [], cache}
    end
  end

  defp fetch_site_for_resource(site_id_bytes, subject) do
    case Database.get_site_by_id(site_id_bytes, subject) do
      %Portal.Site{} = site -> Portal.Cache.Cacheable.to_cache(site)
      nil -> nil
    end
  end

  @spec add_static_device_pool_member(
          t(),
          Portal.StaticDevicePoolMember.t(),
          Authentication.Subject.t()
        ) :: {:ok, [Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}
  def add_static_device_pool_member(cache, %Portal.StaticDevicePoolMember{} = member, subject) do
    rid_bytes = dump!(member.resource_id)
    did_bytes = dump!(member.device_id)

    with true <- connectable_resource?(cache, member.resource_id),
         {:ok, device_addresses} <- ensure_device_addresses(cache, did_bytes, member.device_id, subject) do
      pool_members =
        Map.update(
          cache.pool_members,
          rid_bytes,
          MapSet.new([did_bytes]),
          &MapSet.put(&1, did_bytes)
        )

      cache = %{cache | pool_members: pool_members, device_addresses: device_addresses}

      {updated_pool, cache} = refresh_pool_devices(cache, rid_bytes)

      added = if updated_pool, do: [updated_pool], else: []

      {:ok, added, [], cache}
    else
      _ -> {:ok, [], [], cache}
    end
  end

  defp ensure_device_addresses(cache, did_bytes, device_id, subject) do
    case Map.fetch(cache.device_addresses, did_bytes) do
      {:ok, _existing} ->
        {:ok, cache.device_addresses}

      :error ->
        case Database.get_client_addresses(device_id, subject) do
          nil -> :error
          {_v4, _v6} = addresses -> {:ok, Map.put(cache.device_addresses, did_bytes, addresses)}
        end
    end
  end

  @spec delete_static_device_pool_member(t(), Portal.StaticDevicePoolMember.t()) ::
          {:ok, denied_addresses(), [Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}
  def delete_static_device_pool_member(cache, %Portal.StaticDevicePoolMember{} = member) do
    rid_bytes = dump!(member.resource_id)
    did_bytes = dump!(member.device_id)

    addresses = Map.get(cache.device_addresses, did_bytes)

    pool_members =
      case Map.fetch(cache.pool_members, rid_bytes) do
        {:ok, set} ->
          updated = MapSet.delete(set, did_bytes)

          if MapSet.size(updated) == 0,
            do: Map.delete(cache.pool_members, rid_bytes),
            else: Map.put(cache.pool_members, rid_bytes, updated)

        :error ->
          cache.pool_members
      end

    cache = %{cache | pool_members: pool_members}

    # Only deny access to the device's IPs when it is no longer reachable
    # through any other pool we have access to.
    denied = if device_in_any_pool?(cache, did_bytes), do: nil, else: addresses

    cache = garbage_collect_device_addresses(cache, did_bytes)

    {updated_pool, cache} = refresh_pool_devices(cache, rid_bytes)

    added = if updated_pool, do: [updated_pool], else: []

    {:ok, denied, added, [], cache}
  end

  @doc """
    Reacts to an update of a non-self client device. If the device is a member of any
    connectable pool and its addresses changed, returns the affected pool resources for
    the channel to push as `resource_created_or_updated`.
  """
  @spec handle_member_device_update(t(), Portal.Device.t(), Authentication.Subject.t()) ::
          {:ok, [Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}
  def handle_member_device_update(cache, %Portal.Device{type: :client} = device, _subject) do
    did_bytes = dump!(device.id)
    new_ipv4 = device.ipv4.address
    new_ipv6 = device.ipv6.address

    case Map.fetch(cache.device_addresses, did_bytes) do
      :error ->
        {:ok, [], [], cache}

      {:ok, existing} when existing == {new_ipv4, new_ipv6} ->
        {:ok, [], [], cache}

      {:ok, _existing} ->
        cache = %{
          cache
          | device_addresses: Map.put(cache.device_addresses, did_bytes, {new_ipv4, new_ipv6})
        }

        affected =
          for {rid_bytes, members} <- cache.pool_members,
              MapSet.member?(members, did_bytes),
              do: rid_bytes

        {updated, cache} = refresh_pools(cache, affected)
        {:ok, updated, [], cache}
    end
  end

  defp refresh_pools(cache, rid_bytes_list) do
    Enum.reduce(rid_bytes_list, {[], cache}, fn rid_bytes, {acc, cache_acc} ->
      {updated_pool, cache_acc} = refresh_pool_devices(cache_acc, rid_bytes)
      acc = if updated_pool, do: [updated_pool | acc], else: acc
      {acc, cache_acc}
    end)
  end

  @doc """
    Reacts to deletion of a non-self client device. Removes the device from every pool
    it was a member of, recomputes affected pools' addresses, and returns the device's
    last-known addresses so the channel can push `client_device_access_denied`.

    Cascade `static_device_pool_members` delete events that arrive after this become
    no-ops because the device is no longer in `pool_members`. If the cascade arrives
    *before* this Device delete, that path already pushed the denial and this becomes
    the no-op.
  """
  @spec handle_member_device_delete(t(), Portal.Device.t()) ::
          {:ok, denied_addresses(), [Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}
  def handle_member_device_delete(cache, %Portal.Device{type: :client} = device) do
    did_bytes = dump!(device.id)
    addresses = Map.get(cache.device_addresses, did_bytes)

    affected_pool_ids =
      for {rid_bytes, members} <- cache.pool_members,
          MapSet.member?(members, did_bytes),
          do: rid_bytes

    pool_members =
      cache.pool_members
      |> Enum.map(fn {rid, members} -> {rid, MapSet.delete(members, did_bytes)} end)
      |> Enum.reject(fn {_rid, members} -> MapSet.size(members) == 0 end)
      |> Map.new()

    cache = %{
      cache
      | pool_members: pool_members,
        device_addresses: Map.delete(cache.device_addresses, did_bytes)
    }

    {updated, cache} = refresh_pools(cache, affected_pool_ids)
    {:ok, addresses, updated, [], cache}
  end

  defp hydrate(client, subject) do
    attributes = %{
      actor_id: client.actor_id
    }

    OpenTelemetry.Tracer.with_span "Cache.Cacheable.hydrate", attributes: attributes do
      {_policies, cache} =
        Database.all_policies_for_actor_id!(client.actor_id, subject)
        |> Enum.map_reduce(%{policies: %{}, resources: %{}}, fn policy, cache ->
          resource = Cache.Cacheable.to_cache(policy.resource)
          resources = Map.put(cache.resources, resource.id, resource)

          policy = Cache.Cacheable.to_cache(policy)
          policies = Map.put(cache.policies, policy.id, policy)
          {policy, %{cache | policies: policies, resources: resources}}
        end)

      memberships =
        for membership <- Database.all_memberships_for_actor_id!(client.actor_id, subject),
            into: %{} do
          mid = if membership.id, do: dump!(membership.id), else: nil
          {dump!(membership.group_id), mid}
        end

      cache
      |> Map.put(:memberships, memberships)
      |> Map.put(:connectable_resources, [])
      |> Map.put(:pool_members, %{})
      |> Map.put(:device_addresses, %{})
      |> Map.put(:authorized_device_ipv4s, Database.authorized_ipv4s(client.id, subject))
    end
  end

  defp adapted_resources(conforming_resource_ids, resources, session) do
    for id <- conforming_resource_ids,
        adapted_resource = Map.get(resources, id) |> adapt(session),
        not is_nil(adapted_resource),
        resource_connectable_without_gateway?(adapted_resource) or
          not is_nil(adapted_resource.site) do
      adapted_resource
    end
  end

  defp resource_connectable_without_gateway?(%Cache.Cacheable.Resource{type: type})
       when type in [:static_device_pool, :dynamic_device_pool],
       do: true

  defp resource_connectable_without_gateway?(%Cache.Cacheable.Resource{}), do: false

  defp connectable_resource?(cache, resource_id) do
    resource_id_bytes = dump!(resource_id)
    Enum.any?(cache.connectable_resources, &(&1.id == resource_id_bytes))
  end

  defp adapt(resource, session) do
    Resource.adapt_resource_for_version(resource, session)
  end

  defp load_pool_state(connectable_resources, subject) do
    pool_resource_ids =
      for r <- connectable_resources, r.type == :static_device_pool, do: load!(r.id)

    case pool_resource_ids do
      [] ->
        {%{}, %{}}

      ids ->
        rows = Database.all_member_ips(ids, subject)

        Enum.reduce(rows, {%{}, %{}}, fn {rid_bytes, did_bytes, ipv4, ipv6},
                                         {pool_members_acc, device_addresses_acc} ->
          pool_members_acc =
            Map.update(
              pool_members_acc,
              rid_bytes,
              MapSet.new([did_bytes]),
              &MapSet.put(&1, did_bytes)
            )

          device_addresses_acc = Map.put(device_addresses_acc, did_bytes, {ipv4, ipv6})
          {pool_members_acc, device_addresses_acc}
        end)
    end
  end

  defp render_pool_devices(rid_bytes, pool_members, device_addresses) do
    pool_members
    |> Map.get(rid_bytes, MapSet.new())
    |> Enum.flat_map(fn did_bytes ->
      case Map.fetch(device_addresses, did_bytes) do
        :error -> []
        {:ok, {ipv4, ipv6}} -> [pool_device_entry(did_bytes, ipv4, ipv6)]
      end
    end)
    |> Enum.sort_by(& &1.ipv4.address)
  end

  defp pool_device_entry(did_bytes, ipv4_tuple, ipv6_tuple) do
    %{
      id: load!(did_bytes),
      ipv4: %Postgrex.INET{address: ipv4_tuple, netmask: 32},
      ipv6: %Postgrex.INET{address: ipv6_tuple, netmask: 128}
    }
  end

  defp refresh_pool_devices(cache, rid_bytes) do
    devices = render_pool_devices(rid_bytes, cache.pool_members, cache.device_addresses)

    {updated, connectable} =
      Enum.map_reduce(cache.connectable_resources, nil, fn r, found ->
        if r.id == rid_bytes and r.type == :static_device_pool do
          new_r = %{r | devices: devices}
          {new_r, new_r}
        else
          {r, found}
        end
      end)

    {connectable, %{cache | connectable_resources: updated}}
  end

  defp garbage_collect_device_addresses(cache, did_bytes) do
    if device_in_any_pool?(cache, did_bytes) do
      cache
    else
      %{cache | device_addresses: Map.delete(cache.device_addresses, did_bytes)}
    end
  end

  defp device_in_any_pool?(cache, did_bytes) do
    Enum.any?(cache.pool_members, fn {_rid, set} -> MapSet.member?(set, did_bytes) end)
  end

  defp conforming_resource_ids(policies, client, session, auth_provider_id)
       when is_map(policies) do
    policies
    |> Map.values()
    |> conforming_resource_ids(client, session, auth_provider_id)
  end

  defp conforming_resource_ids(policies, client, session, auth_provider_id) do
    policies
    |> filter_by_conforming_policies_for_client(client, session, auth_provider_id)
    |> Enum.map(& &1.resource_id)
    |> Enum.uniq()
  end

  # Inline functions from Portal.Policies

  defp filter_by_conforming_policies_for_client(
         policies,
         client,
         %ClientSession{} = session,
         auth_provider_id
       ) do
    Enum.filter(policies, fn policy ->
      policy.conditions
      |> Portal.Policies.Evaluator.ensure_conforms(client, session, auth_provider_id)
      |> case do
        {:ok, _expires_at} -> true
        {:error, _violated_properties} -> false
      end
    end)
  end

  @infinity ~U[9999-12-31 23:59:59.999999Z]

  defp longest_conforming_policy_for_client(
         policies,
         client,
         session,
         auth_provider_id,
         expires_at
       ) do
    policies
    |> Enum.reduce(%{failed: [], succeeded: []}, fn policy, acc ->
      case ensure_client_conforms_policy_conditions(policy, client, session, auth_provider_id) do
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
         %Portal.Policy{} = policy,
         client,
         %ClientSession{} = session,
         auth_provider_id
       ) do
    ensure_client_conforms_policy_conditions(
      Cache.Cacheable.to_cache(policy),
      client,
      session,
      auth_provider_id
    )
  end

  defp ensure_client_conforms_policy_conditions(
         %Cache.Cacheable.Policy{} = policy,
         client,
         %ClientSession{} = session,
         auth_provider_id
       ) do
    case Portal.Policies.Evaluator.ensure_conforms(
           policy.conditions,
           client,
           session,
           auth_provider_id
         ) do
      {:ok, expires_at} ->
        {:ok, expires_at}

      {:error, violated_properties} ->
        {:error, {:forbidden, violated_properties: violated_properties}}
    end
  end

  # When both are nil, there is no expiration
  defp min_expires_at(nil, nil), do: nil

  defp min_expires_at(nil, token_expires_at), do: token_expires_at

  defp min_expires_at(policy_expires_at, nil), do: policy_expires_at

  defp min_expires_at(%DateTime{} = policy_expires_at, %DateTime{} = token_expires_at) do
    if DateTime.compare(policy_expires_at, token_expires_at) == :lt do
      policy_expires_at
    else
      token_expires_at
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def all_policies_for_actor_id!(actor_id, subject) do
      # Service accounts don't get access to the "Everyone" group - they must have explicit memberships
      include_everyone_group = subject.actor.type in [:account_user, :account_admin_user]

      from(p in Portal.Policy, as: :policies)
      |> where([policies: p], is_nil(p.disabled_at))
      |> join(:inner, [policies: p], ag in Portal.Group,
        on: ag.id == p.group_id and ag.account_id == p.account_id,
        as: :group
      )
      |> join(:inner, [policies: p], actor in Portal.Actor,
        on: actor.id == ^actor_id and actor.account_id == p.account_id,
        as: :actor
      )
      |> join(:left, [group: ag], m in Portal.Membership,
        on: m.group_id == ag.id and m.account_id == ag.account_id,
        as: :memberships
      )
      |> where(
        [memberships: m, group: ag, actor: a],
        m.actor_id == ^actor_id or
          (^include_everyone_group and
             ag.type == :managed and
             ag.name == "Everyone")
      )
      |> preload(resource: :site)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def all_memberships_for_actor_id!(actor_id, subject) do
      # Get real memberships
      memberships =
        from(m in Portal.Membership, where: m.actor_id == ^actor_id)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> case do
          {:error, :unauthorized} -> []
          list -> list
        end

      # Service accounts don't get access to the "Everyone" group - they must have explicit memberships
      if subject.actor.type in [:account_user, :account_admin_user] do
        # Get the Everyone group for this account (if it exists)
        everyone_group =
          from(g in Portal.Group,
            where:
              g.type == :managed and
                g.name == "Everyone" and
                g.account_id == ^subject.account.id
          )
          |> Safe.scoped(subject, :replica)
          |> Safe.one()

        # Append a synthetic membership for the Everyone group
        case everyone_group do
          nil ->
            memberships

          {:error, :unauthorized} ->
            memberships

          group ->
            memberships ++ [%{group_id: group.id, id: nil}]
        end
      else
        memberships
      end
    end

    def fetch_resource_by_id(id, subject) do
      result =
        from(r in Portal.Resource, where: r.id == ^id)
        |> preload([:site])
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        resource -> {:ok, resource}
      end
    end

    def preload_site(resource) do
      Safe.preload(resource, :site, :replica)
    end

    def get_site_by_id(site_id, subject) when is_binary(site_id) do
      id = Ecto.UUID.load!(site_id)

      from(s in Portal.Site, where: s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
    end

    @doc """
      Returns a list of `{resource_id_bytes, device_id_bytes, ipv4_tuple, ipv6_tuple}`
      for every member of the given pool resources. Member device ipv4/ipv6 are NOT NULL.
    """
    def all_member_ips([], _subject), do: []

    def all_member_ips(resource_ids, subject) do
      from(r in Portal.Resource, as: :resources)
      |> where([resources: r], r.id in ^resource_ids)
      |> join(:inner, [resources: r], m in assoc(r, :static_pool_members), as: :members)
      |> join(:inner, [members: m], c in assoc(m, :client), as: :clients)
      |> where([clients: c], c.type == :client)
      |> select(
        [resources: r, members: m, clients: c],
        {r.id, m.device_id, c.ipv4, c.ipv6}
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, :unauthorized} ->
          []

        rows ->
          Enum.map(rows, fn {rid, did, %Postgrex.INET{address: v4}, %Postgrex.INET{address: v6}} ->
            {Ecto.UUID.dump!(rid), Ecto.UUID.dump!(did), v4, v6}
          end)
      end
    end

    @doc """
      Fetches `{ipv4_tuple, ipv6_tuple}` for a single client device, or `nil` if the
      device cannot be found or the read is unauthorized (e.g. a race with deletion).
      Both addresses are NOT NULL when the device row exists.
    """
    def get_client_addresses(client_id, subject) do
      from(c in Portal.Device,
        where: c.type == :client,
        where: c.id == ^client_id
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
      |> case do
        %Portal.Device{
          ipv4: %Postgrex.INET{address: v4},
          ipv6: %Postgrex.INET{address: v6}
        } ->
          {v4, v6}

        nil ->
          Logger.error("Addresses not found for client", client_id: client_id)
          nil

        {:error, reason} ->
          Logger.error("Failed to fetch addresses for client",
            client_id: client_id,
            reason: inspect(reason)
          )

          nil
      end
    end

    def authorized_ipv4s(client_id, subject) do
      now = DateTime.utc_now()

      from(pa in Portal.PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.receiving_device_id == ^client_id)
      |> where([policy_authorizations: pa], pa.expires_at > ^now)
      |> join(:inner, [policy_authorizations: pa], c in Portal.Device,
        on: c.id == pa.initiating_device_id and c.type == :client,
        as: :clients
      )
      |> select([clients: c], c.ipv4)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, :unauthorized} -> MapSet.new()
        rows -> MapSet.new(rows, & &1.address)
      end
    end
  end
end
