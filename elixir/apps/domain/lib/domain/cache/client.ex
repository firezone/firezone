defmodule Domain.Cache.Client do
  alias __MODULE__.DB

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
            } or nil
          }},

          memberships: %{group_id:uuidv4:16 => membership_id:uuidv4:16},

          connectable_resources: [Cache.Cacheable.Resource.t()]
        }


      For 1,000 policies, 500 resources, 100 memberships, 100 policy_authorizations (per connected client):

        513,400 bytes, 280,700 bytes, 24,640 bytes, 24,640 bytes

      = 843,380 bytes
      = ~ 1 MB (per client)

  """

  alias Domain.{Auth, Client, Cache, Resource, Policy, Version}
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
    # 3. The resource has at least one site associated with it
    :connectable_resources
  ]

  @type t :: %__MODULE__{
          policies: %{Cache.Cacheable.uuid_binary() => Domain.Cache.Cacheable.Policy.t()},
          resources: %{Cache.Cacheable.uuid_binary() => Domain.Cache.Cacheable.Resource.t()},
          memberships: %{Cache.Cacheable.uuid_binary() => Cache.Cacheable.uuid_binary()},
          connectable_resources: [Cache.Cacheable.Resource.t()]
        }

  @doc """
    Authorizes a new policy_authorization for the given client and resource or returns a list of violated properties if
    the resource is not authorized for the client.
  """

  @spec authorize_resource(t(), Domain.Client.t(), Ecto.UUID.t(), Auth.Subject.t()) ::
          {:ok, Cache.Cacheable.Resource.t(), Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer()}
          | {:error, :not_found}
          | {:error, {:forbidden, violated_properties: [atom()]}}

  def authorize_resource(cache, client, resource_id, subject) do
    rid_bytes = dump!(resource_id)

    resource = Enum.find(cache.connectable_resources, :not_found, fn r -> r.id == rid_bytes end)

    policy =
      for({_id, %{resource_id: ^rid_bytes} = p} <- cache.policies, do: p)
      |> longest_conforming_policy_for_client(
        client,
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
    Recomputes the list of connectable resources, returning the newly connectable resources
    and the IDs of resources that are no longer connectable so that the client may update its
    state. This should be called periodically to handle differences due to time-based policy conditions.

    If opts[:toggle] is set to true, we ensure that all added resources also have
  """

  @spec recompute_connectable_resources(
          t() | nil,
          Domain.Client.t(),
          Auth.Subject.t(),
          Keyword.t()
        ) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def recompute_connectable_resources(nil, client, subject) do
    hydrate(client, subject)
    |> recompute_connectable_resources(client, subject)
  end

  def recompute_connectable_resources(cache, client, subject, opts \\ []) do
    {toggle, _opts} = Keyword.pop(opts, :toggle, false)

    connectable_resources =
      cache.policies
      |> conforming_resource_ids(client, subject.credential.auth_provider_id)
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
    Adds a new membership to the cache, potentially fetching the missing policies and resources
    that we don't already have in our cache.

    Since this affects connectable resources, we recompute the connectable resources, which could
    yield deleted IDs, so we send those back.
  """

  @spec add_membership(t(), Domain.Client.t(), Auth.Subject.t()) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def add_membership(cache, client, subject) do
    # TODO: Optimization
    # For simplicity, we rehydrate the cache here. This could be made more efficient by calculating which
    # policies and resources we are missing, and selectively fetching, filtering, and updating the cache.
    # This is not expected to cause an issue in production since in most cases, bulk new memberships would imply
    # bulk new groups, which shouldn't have much if any policies associated to them.
    previously_connectable = cache.connectable_resources

    # Use the previous connectable IDs so that the recomputation yields the difference
    cache = %{hydrate(client, subject) | connectable_resources: previously_connectable}

    recompute_connectable_resources(cache, client, subject)
  end

  @doc """
    Removes all policies, resources, and memberships associated with the given group_id from the cache.
  """

  @spec delete_membership(t(), Domain.Membership.t(), Domain.Client.t(), Auth.Subject.t()) ::
          {:ok, [Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def delete_membership(cache, membership, client, subject) do
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

    recompute_connectable_resources(cache, client, subject)
  end

  @doc """
    Updates any relevant resources in the cache with the new site name.
  """

  @spec update_resources_with_site_name(
          t(),
          Domain.Site.t(),
          Domain.Client.t(),
          Auth.Subject.t()
        ) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def update_resources_with_site_name(cache, site, client, subject) do
    site = Domain.Cache.Cacheable.to_cache(site)

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

  @spec add_policy(t(), Policy.t(), Domain.Client.t(), Auth.Subject.t()) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def add_policy(cache, %{resource_id: resource_id} = policy, client, subject) do
    policy = Domain.Cache.Cacheable.to_cache(policy)

    if Map.has_key?(cache.memberships, policy.group_id) do
      # Add policy to the cache
      cache = %{cache | policies: Map.put(cache.policies, policy.id, policy)}

      # Maybe add resource to the cache if we don't already have it
      cache =
        if Map.has_key?(cache.resources, policy.resource_id) do
          cache
        else
          # Need to fetch the resource from the DB
          {:ok, resource} = DB.fetch_resource_by_id(resource_id, subject)
          resource = DB.preload_site(resource)

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

  @spec update_policy(t(), Policy.t()) :: {:ok, [], [], t()}

  def update_policy(cache, policy) do
    policy = Domain.Cache.Cacheable.to_cache(policy)
    policies = Map.replace(cache.policies, policy.id, policy)
    {:ok, [], [], %{cache | policies: policies}}
  end

  @doc """
    Removes a policy from the cache. If we can't find another policy granting access to the resource,
    we return the deleted resource ID.
  """
  @spec delete_policy(t(), Policy.t(), Domain.Client.t(), Auth.Subject.t()) ::
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
    Updates a resource in the cache with the given resource if it exists.

    If the resource's address has changed and we are no longer compatible with it, we
    need to remove it from the client's list of resources.

    Otherwise, if the resource's address has changed and we are _now_ compatible with it, we need
    to add it to the client's list of resources.

    If the resource has not meaningfully changed (i.e. the cached versions are the same),
    we return only the updated cache.
  """

  @spec update_resource(t(), Domain.Resource.t(), Domain.Client.t(), Auth.Subject.t()) ::
          {:ok, [Domain.Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], t()}

  def update_resource(cache, %Domain.Resource{} = changed_resource, client, subject) do
    resource = Domain.Cache.Cacheable.to_cache(changed_resource)

    if Map.has_key?(cache.resources, resource.id) do
      cached_resource = Map.get(cache.resources, resource.id)
      site_id = Ecto.UUID.dump!(changed_resource.site_id)
      site_changed? = cached_resource.site.id != site_id

      # We need to hydrate the new site name if the site has changed
      site =
        if site_changed? do
          case DB.get_site_by_id(site_id, subject) do
            %Domain.Site{} = site -> Domain.Cache.Cacheable.to_cache(site)
            nil -> nil
          end
        else
          cached_resource.site
        end

      resource = %{resource | site: site}

      # Update the cache
      resources = %{cache.resources | resource.id => resource}
      cache = %{cache | resources: resources}

      # Determine if we need to toggle the resource (delete then add) based on site change and client version
      toggle = Version.resource_cannot_change_sites_on_client?(client) and site_changed?

      recompute_connectable_resources(cache, client, subject, toggle: toggle)
    else
      {:ok, [], [], cache}
    end
  end

  defp hydrate(client, subject) do
    attributes = %{
      actor_id: client.actor_id
    }

    OpenTelemetry.Tracer.with_span "Cache.Cacheable.hydrate", attributes: attributes do
      {_policies, cache} =
        DB.all_policies_for_actor_id!(client.actor_id, subject)
        |> Enum.map_reduce(%{policies: %{}, resources: %{}}, fn policy, cache ->
          resource = Cache.Cacheable.to_cache(policy.resource)
          resources = Map.put(cache.resources, resource.id, resource)

          policy = Cache.Cacheable.to_cache(policy)
          policies = Map.put(cache.policies, policy.id, policy)
          {policy, %{cache | policies: policies, resources: resources}}
        end)

      memberships =
        for membership <- DB.all_memberships_for_actor_id!(client.actor_id, subject),
            into: %{} do
          mid = if membership.id, do: dump!(membership.id), else: nil
          {dump!(membership.group_id), mid}
        end

      cache
      |> Map.put(:memberships, memberships)
      |> Map.put(:connectable_resources, [])
    end
  end

  defp adapted_resources(conforming_resource_ids, resources, client) do
    for id <- conforming_resource_ids,
        adapted_resource = Map.get(resources, id) |> adapt(client),
        not is_nil(adapted_resource),
        not is_nil(adapted_resource.site) do
      adapted_resource
    end
  end

  defp adapt(resource, client) do
    Resource.adapt_resource_for_version(resource, client.last_seen_version)
  end

  defp conforming_resource_ids(policies, client, auth_provider_id) when is_map(policies) do
    policies
    |> Map.values()
    |> conforming_resource_ids(client, auth_provider_id)
  end

  defp conforming_resource_ids(policies, client, auth_provider_id) do
    policies
    |> filter_by_conforming_policies_for_client(client, auth_provider_id)
    |> Enum.map(& &1.resource_id)
    |> Enum.uniq()
  end

  # Inline functions from Domain.Policies

  defp filter_by_conforming_policies_for_client(
         policies,
         %Client{} = client,
         auth_provider_id
       ) do
    Enum.filter(policies, fn policy ->
      policy.conditions
      |> Domain.Policies.Evaluator.ensure_conforms(client, auth_provider_id)
      |> case do
        {:ok, _expires_at} -> true
        {:error, _violated_properties} -> false
      end
    end)
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
      Cache.Cacheable.to_cache(policy),
      client,
      auth_provider_id
    )
  end

  defp ensure_client_conforms_policy_conditions(
         %Cache.Cacheable.Policy{} = policy,
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

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe

    def all_policies_for_actor_id!(actor_id, subject) do
      # Service accounts don't get access to the "Everyone" group - they must have explicit memberships
      include_everyone_group = subject.actor.type in [:account_user, :account_admin_user]

      from(p in Domain.Policy, as: :policies)
      |> where([policies: p], is_nil(p.disabled_at))
      |> join(:inner, [policies: p], ag in assoc(p, :group), as: :group)
      |> join(:inner, [], actor in Domain.Actor, on: actor.id == ^actor_id, as: :actor)
      |> join(:left, [group: ag], m in assoc(ag, :memberships), as: :memberships)
      |> where(
        [memberships: m, group: ag, actor: a],
        m.actor_id == ^actor_id or
          (^include_everyone_group and
             ag.type == :managed and
             is_nil(ag.idp_id) and
             ag.name == "Everyone" and
             ag.account_id == a.account_id)
      )
      |> preload(resource: :site)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def all_memberships_for_actor_id!(actor_id, subject) do
      # Get real memberships
      memberships =
        from(m in Domain.Membership, where: m.actor_id == ^actor_id)
        |> Safe.scoped(subject)
        |> Safe.all()
        |> case do
          {:error, :unauthorized} -> []
          list -> list
        end

      # Service accounts don't get access to the "Everyone" group - they must have explicit memberships
      if subject.actor.type in [:account_user, :account_admin_user] do
        # Get the Everyone group for this account (if it exists)
        everyone_group =
          from(g in Domain.Group,
            where:
              g.type == :managed and
                is_nil(g.idp_id) and
                g.name == "Everyone" and
                g.account_id == ^subject.account.id
          )
          |> Safe.scoped(subject)
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
        from(r in Domain.Resource, where: r.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        resource -> {:ok, resource}
      end
    end

    def preload_site(resource) do
      Safe.preload(resource, :site)
    end

    def get_site(nil, _subject), do: nil

    def get_site(%Domain.Cache.Cacheable.Site{} = site, subject) do
      id = Ecto.UUID.load!(site.id)

      from(s in Domain.Site, where: s.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    def get_site_by_id(site_id, subject) when is_binary(site_id) do
      id = Ecto.UUID.load!(site_id)

      from(s in Domain.Site, where: s.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end
  end
end
