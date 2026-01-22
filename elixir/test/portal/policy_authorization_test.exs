defmodule Portal.PolicyAuthorizationTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.GatewayFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias Portal.PolicyAuthorization

  @valid_ip {100, 64, 0, 1}
  @valid_user_agent "Mozilla/5.0"
  @valid_gateway_ip {100, 64, 0, 2}

  describe "changeset/1 association constraints" do
    test "enforces account association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      {:error, changeset} =
        %PolicyAuthorization{}
        |> cast(
          %{
            account_id: Ecto.UUID.generate(),
            policy_id: policy.id,
            client_id: client.id,
            gateway_id: gateway.id,
            resource_id: resource.id,
            token_id: token.id,
            membership_id: membership.id,
            client_remote_ip: @valid_ip,
            client_user_agent: @valid_user_agent,
            gateway_remote_ip: @valid_gateway_ip,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :account_id,
            :policy_id,
            :client_id,
            :gateway_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
            :expires_at
          ]
        )
        |> PolicyAuthorization.changeset()
        |> Repo.insert()

      assert %{account: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces token association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)

      {:error, changeset} =
        %PolicyAuthorization{}
        |> cast(
          %{
            policy_id: policy.id,
            client_id: client.id,
            gateway_id: gateway.id,
            resource_id: resource.id,
            token_id: Ecto.UUID.generate(),
            membership_id: membership.id,
            client_remote_ip: @valid_ip,
            client_user_agent: @valid_user_agent,
            gateway_remote_ip: @valid_gateway_ip,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :client_id,
            :gateway_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
            :expires_at
          ]
        )
        |> put_assoc(:account, account)
        |> PolicyAuthorization.changeset()
        |> Repo.insert()

      assert %{token: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces policy association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      {:error, changeset} =
        %PolicyAuthorization{}
        |> cast(
          %{
            policy_id: Ecto.UUID.generate(),
            client_id: client.id,
            gateway_id: gateway.id,
            resource_id: resource.id,
            token_id: token.id,
            membership_id: membership.id,
            client_remote_ip: @valid_ip,
            client_user_agent: @valid_user_agent,
            gateway_remote_ip: @valid_gateway_ip,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :client_id,
            :gateway_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
            :expires_at
          ]
        )
        |> put_assoc(:account, account)
        |> PolicyAuthorization.changeset()
        |> Repo.insert()

      assert %{policy: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces client association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      {:error, changeset} =
        %PolicyAuthorization{}
        |> cast(
          %{
            policy_id: policy.id,
            client_id: Ecto.UUID.generate(),
            gateway_id: gateway.id,
            resource_id: resource.id,
            token_id: token.id,
            membership_id: membership.id,
            client_remote_ip: @valid_ip,
            client_user_agent: @valid_user_agent,
            gateway_remote_ip: @valid_gateway_ip,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :client_id,
            :gateway_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
            :expires_at
          ]
        )
        |> put_assoc(:account, account)
        |> PolicyAuthorization.changeset()
        |> Repo.insert()

      assert %{client: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces gateway association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      {:error, changeset} =
        %PolicyAuthorization{}
        |> cast(
          %{
            policy_id: policy.id,
            client_id: client.id,
            gateway_id: Ecto.UUID.generate(),
            resource_id: resource.id,
            token_id: token.id,
            membership_id: membership.id,
            client_remote_ip: @valid_ip,
            client_user_agent: @valid_user_agent,
            gateway_remote_ip: @valid_gateway_ip,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :client_id,
            :gateway_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
            :expires_at
          ]
        )
        |> put_assoc(:account, account)
        |> PolicyAuthorization.changeset()
        |> Repo.insert()

      assert %{gateway: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces resource association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      {:error, changeset} =
        %PolicyAuthorization{}
        |> cast(
          %{
            policy_id: policy.id,
            client_id: client.id,
            gateway_id: gateway.id,
            resource_id: Ecto.UUID.generate(),
            token_id: token.id,
            membership_id: membership.id,
            client_remote_ip: @valid_ip,
            client_user_agent: @valid_user_agent,
            gateway_remote_ip: @valid_gateway_ip,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :client_id,
            :gateway_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
            :expires_at
          ]
        )
        |> put_assoc(:account, account)
        |> PolicyAuthorization.changeset()
        |> Repo.insert()

      assert %{resource: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces membership association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      token = client_token_fixture(account: account, actor: actor)

      {:error, changeset} =
        %PolicyAuthorization{}
        |> cast(
          %{
            policy_id: policy.id,
            client_id: client.id,
            gateway_id: gateway.id,
            resource_id: resource.id,
            token_id: token.id,
            membership_id: Ecto.UUID.generate(),
            client_remote_ip: @valid_ip,
            client_user_agent: @valid_user_agent,
            gateway_remote_ip: @valid_gateway_ip,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :client_id,
            :gateway_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
            :expires_at
          ]
        )
        |> put_assoc(:account, account)
        |> PolicyAuthorization.changeset()
        |> Repo.insert()

      assert %{membership: ["does not exist"]} = errors_on(changeset)
    end

    test "allows nil membership for Everyone group policies" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      token = client_token_fixture(account: account, actor: actor)

      {:ok, pa} =
        %PolicyAuthorization{}
        |> cast(
          %{
            policy_id: policy.id,
            client_id: client.id,
            gateway_id: gateway.id,
            resource_id: resource.id,
            token_id: token.id,
            membership_id: nil,
            client_remote_ip: @valid_ip,
            client_user_agent: @valid_user_agent,
            gateway_remote_ip: @valid_gateway_ip,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :client_id,
            :gateway_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
            :expires_at
          ]
        )
        |> put_assoc(:account, account)
        |> PolicyAuthorization.changeset()
        |> Repo.insert()

      assert pa.membership_id == nil
    end

    test "allows valid associations" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      {:ok, pa} =
        %PolicyAuthorization{}
        |> cast(
          %{
            policy_id: policy.id,
            client_id: client.id,
            gateway_id: gateway.id,
            resource_id: resource.id,
            token_id: token.id,
            membership_id: membership.id,
            client_remote_ip: @valid_ip,
            client_user_agent: @valid_user_agent,
            gateway_remote_ip: @valid_gateway_ip,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [
            :policy_id,
            :client_id,
            :gateway_id,
            :resource_id,
            :token_id,
            :membership_id,
            :client_remote_ip,
            :client_user_agent,
            :gateway_remote_ip,
            :expires_at
          ]
        )
        |> put_assoc(:account, account)
        |> PolicyAuthorization.changeset()
        |> Repo.insert()

      assert pa.account_id == account.id
      assert pa.policy_id == policy.id
      assert pa.client_id == client.id
      assert pa.gateway_id == gateway.id
      assert pa.resource_id == resource.id
      assert pa.token_id == token.id
      assert pa.membership_id == membership.id
    end
  end
end
