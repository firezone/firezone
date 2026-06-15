defmodule Portal.Cache.Reauth do
  @moduledoc """
    Shared helpers for `reauthorize_policy_authorization/1` flows in the gateway and client
    inbound caches. Both `Portal.Cache.Gateway.Database` and
    `Portal.Cache.Client.Authorizations.Database` go through this module instead of calling
    one another directly so the lint rule against cross-module Database calls stays happy.

    The Safe-backed queries live in the nested `Database` module here; the rest of the
    helpers are pure logic.
  """

  alias __MODULE__.Database

  @infinity ~U[9999-12-31 23:59:59.999999Z]

  @doc """
    Loads a client device by `{account_id, id}`. Returns `{:error, :not_found}` if missing.
  """
  defdelegate fetch_client_by_id(account_id, id), to: Database

  @doc """
    Loads the most recent client session for a given client device.
  """
  defdelegate fetch_latest_session_for_client(account_id, client_id), to: Database

  @doc """
    Loads a non-expired client token.
  """
  defdelegate fetch_client_token_by_id(account_id, id), to: Database

  @doc """
    Returns `{:ok, membership_id}` or `{:ok, nil}` for "Everyone"-group policies, or
    `{:error, :membership_not_found}` if neither path applies.
  """
  defdelegate fetch_membership_id_or_nil_for_everyone(account_id, actor_id, group_id),
    to: Database

  @doc """
    Picks the longest-conforming policy for the given client/session/auth_provider, returning
    the policy and its computed expiry (the smaller of the policy condition and token expiry).
  """
  def longest_conforming_policy_for_client(
        policies,
        client,
        session,
        auth_provider_id,
        token_expires_at
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

        {:ok, policy, min_expires_at(condition_expires_at, token_expires_at)}
    end
  end

  defp ensure_client_conforms_policy_conditions(
         %Portal.Policy{} = policy,
         client,
         %Portal.ClientSession{} = session,
         auth_provider_id
       ) do
    ensure_client_conforms_policy_conditions(
      Portal.Cache.Cacheable.to_cache(policy),
      client,
      session,
      auth_provider_id
    )
  end

  defp ensure_client_conforms_policy_conditions(
         %Portal.Cache.Cacheable.Policy{} = policy,
         client,
         %Portal.ClientSession{} = session,
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

  defp min_expires_at(nil, nil),
    do: raise("Both policy_expires_at and token_expires_at cannot be nil")

  defp min_expires_at(nil, token_expires_at), do: token_expires_at

  defp min_expires_at(policy_expires_at, nil), do: policy_expires_at

  defp min_expires_at(%DateTime{} = policy_expires_at, %DateTime{} = token_expires_at) do
    if DateTime.compare(policy_expires_at, token_expires_at) == :lt do
      policy_expires_at
    else
      token_expires_at
    end
  end

  @doc """
    Casts and validates the attrs into a Portal.PolicyAuthorization changeset.
    `receiver_remote_ip` is required: a policy_authorization is only ever created after
    delivery to the receiving device succeeds, so the receiver must be online and we
    must know its remote IP from the latest session/presence record.
  """
  def create_policy_authorization_changeset(attrs) do
    import Ecto.Changeset

    fields =
      ~w[token_id policy_id initiating_device_id receiving_device_id resource_id membership_id
                  account_id
                  expires_at
                  initiator_remote_ip initiator_user_agent
                  receiver_remote_ip]a

    %Portal.PolicyAuthorization{}
    |> cast(attrs, fields)
    |> validate_required(fields -- [:membership_id])
    |> Portal.PolicyAuthorization.changeset()
  end

  defmodule Database do
    alias Portal.Safe
    import Ecto.Query

    def fetch_client_by_id(account_id, id) do
      client =
        from(c in Portal.Device, as: :clients)
        |> where([clients: c], c.type == :client)
        |> where([clients: c], c.account_id == ^account_id and c.id == ^id)
        |> Safe.unscoped(:replica)
        |> Safe.one()

      if client do
        {:ok, client}
      else
        {:error, :not_found}
      end
    end

    def fetch_latest_session_for_client(account_id, client_id) do
      result =
        from(s in Portal.ClientSession,
          where: s.account_id == ^account_id and s.device_id == ^client_id,
          order_by: [desc_nulls_last: s.timestamp],
          limit: 1
        )
        |> Safe.unscoped(:replica)
        |> Safe.one()

      if result, do: {:ok, result}, else: {:error, :not_found}
    end

    def fetch_client_token_by_id(account_id, id) do
      result =
        from(t in Portal.ClientToken,
          where: t.account_id == ^account_id,
          where: t.id == ^id,
          where: t.expires_at > ^DateTime.utc_now()
        )
        |> Safe.unscoped(:replica)
        |> Safe.one()

      if result do
        {:ok, result}
      else
        {:error, :not_found}
      end
    end

    def fetch_membership_id_or_nil_for_everyone(account_id, actor_id, group_id) do
      case fetch_membership_by_actor_id_and_group_id(account_id, actor_id, group_id) do
        {:ok, membership} ->
          {:ok, membership.id}

        {:error, :not_found} ->
          if everyone_group?(account_id, group_id) do
            {:ok, nil}
          else
            {:error, :membership_not_found}
          end
      end
    end

    defp fetch_membership_by_actor_id_and_group_id(account_id, actor_id, group_id) do
      from(m in Portal.Membership,
        where: m.account_id == ^account_id,
        where: m.actor_id == ^actor_id,
        where: m.group_id == ^group_id
      )
      |> Safe.unscoped(:replica)
      |> Safe.one(fallback_to_primary: true)
      |> case do
        nil -> {:error, :not_found}
        membership -> {:ok, membership}
      end
    end

    defp everyone_group?(account_id, group_id) do
      from(g in Portal.Group,
        where:
          g.account_id == ^account_id and
            g.id == ^group_id and
            g.type == :managed and
            is_nil(g.idp_id) and
            g.name == "Everyone"
      )
      |> Safe.unscoped(:replica)
      |> Safe.exists?()
    end
  end
end
