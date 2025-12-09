defmodule Domain.PolicyAuthorizationFixtures do
  @moduledoc """
  Test helpers for creating policy authorizations.
  """

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.ClientFixtures
  import Domain.GatewayFixtures
  import Domain.GroupFixtures
  import Domain.MembershipFixtures
  import Domain.PolicyFixtures
  import Domain.ResourceFixtures
  import Domain.SiteFixtures
  import Domain.TokenFixtures

  @doc """
  Generate valid policy authorization attributes with sensible defaults.
  """
  def valid_policy_authorization_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      client_remote_ip: {100, 64, 0, 1},
      client_user_agent: "Mozilla/5.0",
      gateway_remote_ip: {100, 64, 0, 2}
    })
  end

  @doc """
  Generate a policy authorization with valid default attributes.

  The policy authorization requires:
  - account
  - policy (which links group and resource)
  - client
  - gateway
  - token
  - membership (optional, for non-"Everyone" group policies)

  ## Examples

      policy_authorization = policy_authorization_fixture()
      policy_authorization = policy_authorization_fixture(client: client, resource: resource)

  """
  def policy_authorization_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account =
      cond do
        client = Map.get(attrs, :client) ->
          client.account || Domain.Repo.preload(client, :account).account

        gateway = Map.get(attrs, :gateway) ->
          gateway.account || Domain.Repo.preload(gateway, :account).account

        resource = Map.get(attrs, :resource) ->
          resource.account || Domain.Repo.preload(resource, :account).account

        true ->
          Map.get(attrs, :account) || account_fixture()
      end

    # Get or create actor
    actor = Map.get(attrs, :actor) || actor_fixture(account: account)

    # Get or create client
    client = Map.get(attrs, :client) || client_fixture(account: account, actor: actor)

    # Get or create site
    site = Map.get(attrs, :site) || site_fixture(account: account)

    # Get or create gateway
    gateway = Map.get(attrs, :gateway) || gateway_fixture(account: account, site: site)

    # Get or create resource
    resource = Map.get(attrs, :resource) || resource_fixture(account: account, site: site)

    # Get or create group
    group = Map.get(attrs, :group) || group_fixture(account: account)

    # Get or create policy - check if one already exists for this group/resource combo
    policy =
      Map.get_lazy(attrs, :policy, fn ->
        # Try to find an existing policy for this group and resource
        case Domain.Repo.get_by(Domain.Policy,
               account_id: account.id,
               group_id: group.id,
               resource_id: resource.id
             ) do
          nil -> policy_fixture(account: account, group: group, resource: resource)
          existing -> existing
        end
      end)

    # Get or create membership - check if one already exists for this actor/group combo
    membership =
      Map.get_lazy(attrs, :membership, fn ->
        case Domain.Repo.get_by(Domain.Membership,
               account_id: account.id,
               actor_id: actor.id,
               group_id: group.id
             ) do
          nil -> membership_fixture(account: account, actor: actor, group: group)
          existing -> existing
        end
      end)

    # Get or create token
    token =
      case Map.get(attrs, :token) do
        nil ->
          client_token_fixture(account: account, actor: actor)

        existing ->
          existing
      end

    # Get expires_at
    expires_at =
      Map.get(attrs, :expires_at, DateTime.add(DateTime.utc_now(), 3600, :second))

    # Build policy authorization attrs
    pa_attrs =
      attrs
      |> Map.drop([
        :account,
        :actor,
        :client,
        :gateway,
        :resource,
        :group,
        :policy,
        :membership,
        :token,
        :site,
        :subject
      ])
      |> Map.put(:account_id, account.id)
      |> Map.put(:policy_id, policy.id)
      |> Map.put(:client_id, client.id)
      |> Map.put(:gateway_id, gateway.id)
      |> Map.put(:resource_id, resource.id)
      |> Map.put(:token_id, token.id)
      |> Map.put(:membership_id, membership.id)
      |> Map.put(:expires_at, expires_at)
      |> valid_policy_authorization_attrs()

    {:ok, policy_authorization} =
      %Domain.PolicyAuthorization{}
      |> Ecto.Changeset.cast(pa_attrs, [
        :account_id,
        :policy_id,
        :client_id,
        :gateway_id,
        :resource_id,
        :token_id,
        :membership_id,
        :expires_at,
        :client_remote_ip,
        :client_user_agent,
        :gateway_remote_ip
      ])
      |> Domain.PolicyAuthorization.changeset()
      |> Domain.Repo.insert()

    policy_authorization
  end

  @doc """
  Generate an expired policy authorization.
  """
  def expired_policy_authorization_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    policy_authorization_fixture(
      Map.put(attrs, :expires_at, DateTime.add(DateTime.utc_now(), -3600, :second))
    )
  end

  @doc """
  Generate a policy authorization expiring soon.
  """
  def expiring_policy_authorization_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    policy_authorization_fixture(
      Map.put(attrs, :expires_at, DateTime.add(DateTime.utc_now(), 60, :second))
    )
  end
end
