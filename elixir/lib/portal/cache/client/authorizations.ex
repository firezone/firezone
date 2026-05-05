defmodule Portal.Cache.Client.Authorizations do
  @moduledoc """
    This cache is used in the client channel processes to maintain a materialized view of inbound
    policy_authorizations — entries where the channel's client is the `receiving_device_id` of a
    policy_authorization. It mirrors `Portal.Cache.Gateway` for client-to-client device pool flows.

    Data structure:

      %{{client_id:uuidv4:16, resource_id:uuidv4:16}:16 => %{policy_authorization_id:uuidv4:16 => expires_at:integer:8}:40}

    Memory characteristics match `Portal.Cache.Gateway` since the structure is identical.
  """

  alias Portal.{Cache, Device, PolicyAuthorization}
  alias __MODULE__.Database
  import Ecto.UUID, only: [dump!: 1, load!: 1]

  require OpenTelemetry.Tracer

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
  @spec hydrate(Device.t()) :: t()
  def hydrate(client) do
    OpenTelemetry.Tracer.with_span "Portal.Cache.Client.Authorizations.hydrate",
      attributes: %{
        client_id: client.id,
        account_id: client.account_id
      } do
      Database.all_client_policy_authorizations_for_cache!(client)
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

    for {tuple, policy_authorization_id_map} <- cache,
        filtered =
          Map.reject(policy_authorization_id_map, fn {_paid_bytes, expires_at_unix} ->
            expires_at_unix < now_unix
          end),
        map_size(filtered) > 0,
        into: %{} do
      {tuple, filtered}
    end
  end

  @doc """
    Add a policy_authorization to the cache. Returns the updated cache.
  """
  @spec put(t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: t()
  def put(%{} = cache, client_id, resource_id, policy_authorization_id, %DateTime{} = expires_at) do
    tuple = {dump!(client_id), dump!(resource_id)}

    policy_authorization_id_map =
      Map.get(cache, tuple, %{})
      |> Map.put(dump!(policy_authorization_id), DateTime.to_unix(expires_at, :second))

    Map.put(cache, tuple, policy_authorization_id_map)
  end

  @doc """
    Delete a policy_authorization from the cache. If another policy_authorization exists for the same
    {initiating_client, resource} pair, return its max expiration. Otherwise, optimistically try to
    create a replacement policy_authorization so a transient policy churn doesn't tear down an
    active client-to-client tunnel. If reauthorization fails, return `:unauthorized` so the channel
    can push `client_device_access_denied`.
  """
  @spec reauthorize_deleted_policy_authorization(t(), PolicyAuthorization.t()) ::
          {:ok, non_neg_integer(), t()} | {:error, :unauthorized, t()} | {:error, :not_found}
  def reauthorize_deleted_policy_authorization(
        cache,
        %PolicyAuthorization{} = policy_authorization
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

  @doc """
    Check if the cache has a resource entry for the given resource_id.
  """
  @spec has_resource?(t(), Ecto.UUID.t()) :: boolean()
  def has_resource?(%{} = cache, resource_id) do
    rid_bytes = dump!(resource_id)

    cache
    |> Map.keys()
    |> Enum.any?(fn {_, rid} -> rid == rid_bytes end)
  end

  @doc """
    Return a list of all `{client_id, resource_id}` pairs matching the given resource ID.
  """
  @spec all_pairs_for_resource(t(), Ecto.UUID.t()) :: [{Ecto.UUID.t(), Ecto.UUID.t()}]
  def all_pairs_for_resource(%{} = cache, resource_id) do
    rid_bytes = dump!(resource_id)

    cache
    |> Enum.filter(fn {{_, rid}, _} -> rid == rid_bytes end)
    |> Enum.map(fn {{cid, _}, _} -> {load!(cid), resource_id} end)
  end

  defp policy_authorization_key(%PolicyAuthorization{
         initiating_device_id: client_id,
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
          {nil, _} -> {:not_found, cache}
          {_expiration, remaining} -> finalize_remaining(cache, key, remaining)
        end
    end
  end

  defp finalize_remaining(cache, key, remaining_policy_authorizations) do
    now_unix = DateTime.utc_now() |> DateTime.to_unix(:second)
    fresh = Map.reject(remaining_policy_authorizations, fn {_paid, exp} -> exp < now_unix end)

    if fresh == %{} do
      {:last_policy_authorization_removed, Map.delete(cache, key)}
    else
      {:policy_authorization_removed, fresh, Map.put(cache, key, fresh)}
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

  defmodule Database do
    alias Portal.Cache.Reauth
    alias Portal.Safe
    import Ecto.Query
    require Logger

    def all_client_policy_authorizations_for_cache!(%{account_id: _, id: _} = client) do
      now = DateTime.utc_now()

      from(pa in Portal.PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.account_id == ^client.account_id)
      |> where([policy_authorizations: pa], pa.receiving_device_id == ^client.id)
      |> where([policy_authorizations: pa], pa.expires_at > ^now)
      |> select(
        [policy_authorizations: pa],
        {{pa.initiating_device_id, pa.resource_id}, {pa.id, pa.expires_at}}
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end

    def all_policies_for_resource_id_and_actor_id!(account_id, resource_id, actor_id) do
      from(p in Portal.Policy, as: :policies)
      |> where([policies: p], is_nil(p.disabled_at))
      |> where([policies: p], p.account_id == ^account_id)
      |> where([policies: p], p.resource_id == ^resource_id)
      |> join(:inner, [policies: p], ag in assoc(p, :group), as: :group)
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
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end

    def reauthorize_policy_authorization(%Portal.PolicyAuthorization{} = policy_authorization) do
      with {:ok, client} <-
             Reauth.fetch_client_by_id(
               policy_authorization.account_id,
               policy_authorization.initiating_device_id
             ),
           {:ok, session} <-
             Reauth.fetch_latest_session_for_client(
               policy_authorization.account_id,
               policy_authorization.initiating_device_id
             ),
           {:ok, token} <-
             Reauth.fetch_client_token_by_id(
               policy_authorization.account_id,
               policy_authorization.token_id
             ),
           # Client-to-client flows always target static_device_pool resources, which carry
           # no site, so we drop the gateway flow's site filter when looking for replacements.
           policies when policies != [] <-
             all_policies_for_resource_id_and_actor_id!(
               policy_authorization.account_id,
               policy_authorization.resource_id,
               client.actor_id
             ),
           {:ok, policy, expires_at} <-
             Reauth.longest_conforming_policy_for_client(
               policies,
               client,
               session,
               token.auth_provider_id,
               policy_authorization.expires_at
             ),
           {:ok, membership_id} <-
             Reauth.fetch_membership_id_or_nil_for_everyone(
               policy_authorization.account_id,
               client.actor_id,
               policy.group_id
             ),
           {:ok, new_policy_authorization} <-
             Reauth.create_policy_authorization_changeset(%{
               token_id: policy_authorization.token_id,
               policy_id: policy.id,
               initiating_device_id: policy_authorization.initiating_device_id,
               receiving_device_id: policy_authorization.receiving_device_id,
               resource_id: policy_authorization.resource_id,
               membership_id: membership_id,
               account_id: policy_authorization.account_id,
               initiator_remote_ip: session.remote_ip,
               initiator_user_agent: session.user_agent,
               receiver_remote_ip: policy_authorization.receiver_remote_ip,
               expires_at: expires_at
             })
             |> Safe.unscoped()
             |> Safe.insert() do
        Logger.info("Reauthorized client-to-client policy_authorization",
          old_policy_authorization: inspect(policy_authorization),
          new_policy_authorization: inspect(new_policy_authorization)
        )

        {:ok, new_policy_authorization}
      else
        reason ->
          Logger.info("Failed to reauthorize client-to-client policy_authorization",
            old_policy_authorization: inspect(policy_authorization),
            reason: inspect(reason)
          )

          :error
      end
    end
  end
end
