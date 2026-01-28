defmodule Portal.Cache.Gateway do
  @moduledoc """
    This cache is used in the gateway channel processes to maintain a materialized view of the gateway policy_authorization state.
    The cache is updated via WAL messages streamed from the Portal.Changes.ReplicationConnection module.

    We use basic data structures and binary representations instead of full Ecto schema structs
    to minimize memory usage. The rough structure of the two cached data structures and some napkin math
    on their memory usage (assuming "worst-case" usage scenarios) is described below.

    Data structure:

      %{{client_id:uuidv4:16, resource_id:uuidv4:16}:16 => %{policy_authorization_id:uuidv4:16 => expires_at:integer:8}:40}:(num_keys * 1.8 * 8 - large map)

    For 10,000 client/resource entries, consisting of 10 policy_authorizations each:

      10,000 keys, 100,000 values
      480,000 bytes (outer map keys), 6,400,000 bytes (inner map), 144,000 bytes (outer map overhead)

    = 7,024,000
    = ~ 7 MB
  """

  alias Portal.{Cache, Gateway}
  alias __MODULE__.Database
  import Ecto.UUID, only: [dump!: 1, load!: 1]

  require OpenTelemetry.Tracer

  # Type definitions
  @type client_resource_key ::
          {client_id :: Cache.Cacheable.uuid_binary(),
           resource_id :: Cache.Cacheable.uuid_binary()}
  @type policy_authorization_map :: %{
          (policy_authorization_id :: Cache.Cacheable.uuid_binary()) =>
            expires_at_unix :: non_neg_integer
        }
  @type t :: %{client_resource_key() => policy_authorization_map()}

  @doc """
    Fetches relevant policy_authorizations from the DB and transforms them into the cache format.
  """
  @spec hydrate(Gateway.t()) :: t()
  def hydrate(gateway) do
    OpenTelemetry.Tracer.with_span "Portal.Cache.hydrate_policy_authorizations",
      attributes: %{
        gateway_id: gateway.id,
        account_id: gateway.account_id
      } do
      Database.all_gateway_policy_authorizations_for_cache!(gateway)
      |> Enum.reduce(%{}, fn {{client_id, resource_id}, {policy_authorization_id, expires_at}},
                             acc ->
        cid_bytes = dump!(client_id)
        rid_bytes = dump!(resource_id)
        paid_bytes = dump!(policy_authorization_id)
        expires_at_unix = DateTime.to_unix(expires_at, :second)

        policy_authorization_id_map = Map.get(acc, {cid_bytes, rid_bytes}, %{})

        Map.put(
          acc,
          {cid_bytes, rid_bytes},
          Map.put(policy_authorization_id_map, paid_bytes, expires_at_unix)
        )
      end)
    end
  end

  @doc """
    Removes expired policy_authorizations from the cache.
  """
  @spec prune(t()) :: t()
  def prune(cache) do
    now_unix = DateTime.utc_now() |> DateTime.to_unix(:second)

    # 1. Remove individual policy_authorizations older than 14 days, then remove access entry if no
    # policy_authorizations left
    for {tuple, policy_authorization_id_map} <- cache,
        filtered =
          Map.reject(policy_authorization_id_map, fn {_fid_bytes, expires_at_unix} ->
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

      policy_authorization_id_map ->
        # Use longest expiration to minimize unnecessary access churn
        policy_authorization_id_map
        |> Map.values()
        |> Enum.max()
    end
  end

  @doc """
    Add a policy_authorization to the cache. Returns the updated cache.
  """
  @spec put(t(), Ecto.UUID.t(), Cache.Cacheable.uuid_binary(), Ecto.UUID.t(), DateTime.t()) :: t()
  def put(%{} = cache, client_id, rid_bytes, policy_authorization_id, %DateTime{} = expires_at) do
    tuple = {dump!(client_id), rid_bytes}

    policy_authorization_id_map =
      Map.get(cache, tuple, %{})
      |> Map.put(dump!(policy_authorization_id), DateTime.to_unix(expires_at, :second))

    Map.put(cache, tuple, policy_authorization_id_map)
  end

  @doc """
    Delete a policy_authorization from the cache. If another policy_authorization exists for the same client/resource,
    we return the max expiration for that resource.
    If not, we optimistically try to reauthorize access by creating a new policy_authorization. This prevents
    removal of access on the Gateway but not the client, which would cause connectivity issues.
    If we can't create a new authorization, we send unauthorized so that access is removed.
  """
  @spec reauthorize_deleted_policy_authorization(t(), Portal.PolicyAuthorization.t()) ::
          {:ok, non_neg_integer(), t()} | {:error, :unauthorized, t()} | {:error, :not_found}
  def reauthorize_deleted_policy_authorization(
        cache,
        %Portal.PolicyAuthorization{} = policy_authorization
      ) do
    key = policy_authorization_key(policy_authorization)
    policy_authorization_id = dump!(policy_authorization.id)

    case get_and_remove_policy_authorization(cache, key, policy_authorization_id) do
      {:not_found, _cache} ->
        {:error, :not_found}

      {:last_policy_authorization_removed, cache} ->
        handle_last_policy_authorization_removal(cache, key, policy_authorization)

      {:policy_authorization_removed, remaining_policy_authorizations, cache} ->
        max_expiration = remaining_policy_authorizations |> Map.values() |> Enum.max()
        {:ok, max_expiration, cache}
    end
  end

  defp policy_authorization_key(%Portal.PolicyAuthorization{
         client_id: client_id,
         resource_id: resource_id
       }) do
    {dump!(client_id), dump!(resource_id)}
  end

  defp get_and_remove_policy_authorization(cache, key, policy_authorization_id) do
    case Map.fetch(cache, key) do
      :error ->
        {:not_found, cache}

      {:ok, policy_authorization_map} ->
        case Map.pop(policy_authorization_map, policy_authorization_id) do
          {nil, _} ->
            {:not_found, cache}

          {_expiration, remaining_policy_authorizations}
          when remaining_policy_authorizations == %{} ->
            {:last_policy_authorization_removed, Map.delete(cache, key)}

          {_expiration, remaining_policy_authorizations} ->
            {:policy_authorization_removed, remaining_policy_authorizations,
             Map.put(cache, key, remaining_policy_authorizations)}
        end
    end
  end

  defp handle_last_policy_authorization_removal(cache, key, policy_authorization) do
    case Database.reauthorize_policy_authorization(policy_authorization) do
      {:ok, new_policy_authorization} ->
        new_policy_authorization_id = dump!(new_policy_authorization.id)
        expires_at_unix = DateTime.to_unix(new_policy_authorization.expires_at, :second)
        new_policy_authorization_map = %{new_policy_authorization_id => expires_at_unix}

        {:ok, expires_at_unix, Map.put(cache, key, new_policy_authorization_map)}

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

  # Inline functions from Portal.PolicyAuthorizations - moved to DB module

  defmodule Database do
    alias Portal.Safe
    import Ecto.Query
    import Ecto.Changeset
    require Logger

    @infinity ~U[9999-12-31 23:59:59.999999Z]

    defp repo, do: Portal.Config.fetch_env!(:portal, :replica_repo)

    def all_gateway_policy_authorizations_for_cache!(%Portal.Gateway{} = gateway) do
      now = DateTime.utc_now()

      from(f in Portal.PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^gateway.account_id)
      |> where([policy_authorizations: f], f.gateway_id == ^gateway.id)
      |> where([policy_authorizations: f], f.expires_at > ^now)
      |> select(
        [policy_authorizations: f],
        {{f.client_id, f.resource_id}, {f.id, f.expires_at}}
      )
      |> Safe.unscoped(repo())
      |> Safe.all()
    end

    def fetch_client_by_id!(id, _opts \\ []) do
      from(c in Portal.Client, as: :clients)
      |> where([clients: c], c.id == ^id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def fetch_gateway_by_id(id) do
      result =
        from(g in Portal.Gateway, as: :gateways)
        |> where([gateways: g], g.id == ^id)
        |> Safe.unscoped()
        |> Safe.one()

      if result do
        {:ok, result}
      else
        {:error, :not_found}
      end
    end

    def fetch_client_token_by_id(id) do
      result =
        from(t in Portal.ClientToken,
          where: t.id == ^id,
          where: t.expires_at > ^DateTime.utc_now()
        )
        |> Safe.unscoped()
        |> Safe.one()

      if result do
        {:ok, result}
      else
        {:error, :not_found}
      end
    end

    def fetch_membership_by_actor_id_and_group_id(actor_id, group_id) do
      from(m in Portal.Membership,
        where: m.actor_id == ^actor_id,
        where: m.group_id == ^group_id
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        membership -> {:ok, membership}
      end
    end

    def everyone_group?(group_id, account_id) do
      from(g in Portal.Group,
        where:
          g.id == ^group_id and
            g.type == :managed and
            is_nil(g.idp_id) and
            g.name == "Everyone" and
            g.account_id == ^account_id
      )
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def fetch_membership_id_or_nil_for_everyone(actor_id, group_id, account_id) do
      case fetch_membership_by_actor_id_and_group_id(actor_id, group_id) do
        {:ok, membership} ->
          {:ok, membership.id}

        {:error, :not_found} ->
          if everyone_group?(group_id, account_id) do
            {:ok, nil}
          else
            {:error, :membership_not_found}
          end
      end
    end

    def all_policies_in_site_for_resource_id_and_actor_id!(
          account_id,
          site_id,
          resource_id,
          actor_id
        ) do
      from(p in Portal.Policy, as: :policies)
      |> where([policies: p], is_nil(p.disabled_at))
      |> where([policies: p], p.account_id == ^account_id)
      |> where([policies: p], p.resource_id == ^resource_id)
      |> join(:inner, [policies: p], ag in assoc(p, :group), as: :group)
      |> join(:inner, [policies: p], r in assoc(p, :resource), as: :resource)
      |> where([resource: r], r.site_id == ^site_id)
      |> join(:inner, [], actor in Portal.Actor,
        on: actor.id == ^actor_id and actor.account_id == ^account_id,
        as: :actor
      )
      |> join(:left, [group: ag], m in assoc(ag, :memberships), as: :memberships)
      |> where(
        [memberships: m, group: ag, actor: a],
        m.actor_id == ^actor_id or
          (ag.type == :managed and
             is_nil(ag.idp_id) and
             ag.name == "Everyone" and
             ag.account_id == a.account_id)
      )
      |> preload(resource: :site)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def insert_policy_authorization(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def reauthorize_policy_authorization(%Portal.PolicyAuthorization{} = policy_authorization) do
      with client when not is_nil(client) <- fetch_client_by_id!(policy_authorization.client_id),
           {:ok, token} <- fetch_client_token_by_id(policy_authorization.token_id),
           {:ok, gateway} <- fetch_gateway_by_id(policy_authorization.gateway_id),
           # We only want to reauthorize the resource for this gateway if the resource is still connected to its
           # site.
           policies when policies != [] <-
             all_policies_in_site_for_resource_id_and_actor_id!(
               policy_authorization.account_id,
               gateway.site_id,
               policy_authorization.resource_id,
               client.actor_id
             ),
           {:ok, policy, expires_at} <-
             longest_conforming_policy_for_client(
               policies,
               client,
               token,
               policy_authorization.expires_at
             ),
           # Membership is optional only for "Everyone" group policies
           {:ok, membership_id} <-
             fetch_membership_id_or_nil_for_everyone(
               client.actor_id,
               policy.group_id,
               policy_authorization.account_id
             ),
           {:ok, new_policy_authorization} <-
             create_policy_authorization_changeset(%{
               token_id: policy_authorization.token_id,
               policy_id: policy.id,
               client_id: policy_authorization.client_id,
               gateway_id: policy_authorization.gateway_id,
               resource_id: policy_authorization.resource_id,
               membership_id: membership_id,
               account_id: policy_authorization.account_id,
               client_remote_ip: client.last_seen_remote_ip,
               client_user_agent: client.last_seen_user_agent,
               gateway_remote_ip: policy_authorization.gateway_remote_ip,
               expires_at: expires_at
             })
             |> Safe.unscoped()
             |> Safe.insert() do
        Logger.info("Reauthorized policy_authorization",
          old_policy_authorization: inspect(policy_authorization),
          new_policy_authorization: inspect(new_policy_authorization)
        )

        {:ok, new_policy_authorization}
      else
        reason ->
          Logger.info("Failed to reauthorize policy_authorization",
            old_policy_authorization: inspect(policy_authorization),
            reason: inspect(reason)
          )

          :error
      end
    end

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
           %Portal.Policy{} = policy,
           %Portal.Client{} = client,
           auth_provider_id
         ) do
      ensure_client_conforms_policy_conditions(
        Portal.Cache.Cacheable.to_cache(policy),
        client,
        auth_provider_id
      )
    end

    defp ensure_client_conforms_policy_conditions(
           %Portal.Cache.Cacheable.Policy{} = policy,
           %Portal.Client{} = client,
           auth_provider_id
         ) do
      case Portal.Policies.Evaluator.ensure_conforms(policy.conditions, client, auth_provider_id) do
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

    defp create_policy_authorization_changeset(attrs) do
      fields = ~w[token_id policy_id client_id gateway_id resource_id membership_id
                  account_id
                  expires_at
                  client_remote_ip client_user_agent
                  gateway_remote_ip]a

      %Portal.PolicyAuthorization{}
      |> cast(attrs, fields)
      |> validate_required(fields -- [:membership_id])
      |> Portal.PolicyAuthorization.changeset()
    end
  end
end
