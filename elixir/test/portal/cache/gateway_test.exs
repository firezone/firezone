defmodule Portal.Cache.GatewayTest do
  use Portal.DataCase, async: true

  alias Portal.Cache
  alias Portal.PolicyAuthorization

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.ClientSessionFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  import Ecto.Query, only: [from: 2]
  import Ecto.UUID, only: [dump!: 1]

  describe "hydrate/1" do
    test "returns an empty cache when there are no policy_authorizations" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      assert Cache.Gateway.hydrate(gateway) == %{}
    end

    test "loads matching policy_authorizations into the cache" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      identity_fixture(actor: actor, account: account)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      client = client_fixture(account: account, actor: actor)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          gateway: gateway,
          client: client
        )

      cache = Cache.Gateway.hydrate(gateway)

      key = {dump!(client.id), dump!(policy_authorization.resource_id)}
      assert %{^key => paid_map} = cache
      assert Map.fetch!(paid_map, dump!(policy_authorization.id)) ==
               DateTime.to_unix(policy_authorization.expires_at, :second)
    end

    test "ignores expired policy_authorizations" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      identity_fixture(actor: actor, account: account)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      client = client_fixture(account: account, actor: actor)

      expired_policy_authorization_fixture(
        account: account,
        actor: actor,
        gateway: gateway,
        client: client
      )

      assert Cache.Gateway.hydrate(gateway) == %{}
    end
  end

  describe "get/3" do
    test "returns nil when the {client, resource} pair is not in the cache" do
      assert Cache.Gateway.get(%{}, Ecto.UUID.generate(), Ecto.UUID.generate()) == nil
    end

    test "returns the longest expiration for the pair" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      shorter = DateTime.add(now, 60, :second)
      longer = DateTime.add(now, 3600, :second)

      cache =
        %{}
        |> Cache.Gateway.put(client_id, dump!(resource_id), Ecto.UUID.generate(), shorter)
        |> Cache.Gateway.put(client_id, dump!(resource_id), Ecto.UUID.generate(), longer)

      assert Cache.Gateway.get(cache, client_id, resource_id) ==
               DateTime.to_unix(longer, :second)
    end
  end

  describe "put/5" do
    test "inserts a new entry" do
      cache = %{}
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Cache.Gateway.put(cache, client_id, dump!(resource_id), paid, expires_at)

      key = {dump!(client_id), dump!(resource_id)}
      assert %{^key => paid_map} = cache
      assert Map.fetch!(paid_map, dump!(paid)) == DateTime.to_unix(expires_at, :second)
    end
  end

  describe "prune/1" do
    test "drops expired authorizations" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expired = DateTime.utc_now() |> DateTime.add(-3600, :second)

      cache = Cache.Gateway.put(%{}, client_id, dump!(resource_id), paid, expired)

      assert Cache.Gateway.prune(cache) == %{}
    end
  end

  describe "has_resource?/2" do
    test "returns true when the resource is present" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Cache.Gateway.put(%{}, client_id, dump!(resource_id), paid, expires_at)

      assert Cache.Gateway.has_resource?(cache, resource_id)
    end

    test "returns false when the resource is not present" do
      refute Cache.Gateway.has_resource?(%{}, Ecto.UUID.generate())
    end
  end

  describe "all_pairs_for_resource/2" do
    test "returns matching {client, resource} pairs" do
      resource_id = Ecto.UUID.generate()
      client_a = Ecto.UUID.generate()
      client_b = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache =
        %{}
        |> Cache.Gateway.put(client_a, dump!(resource_id), Ecto.UUID.generate(), expires_at)
        |> Cache.Gateway.put(client_b, dump!(resource_id), Ecto.UUID.generate(), expires_at)

      pairs = Cache.Gateway.all_pairs_for_resource(cache, resource_id)
      assert Enum.sort(pairs) ==
               Enum.sort([{client_a, resource_id}, {client_b, resource_id}])
    end
  end

  describe "reauthorize_deleted_policy_authorization/2" do
    test "returns :not_found when the {client, resource} pair is not present" do
      pa = %PolicyAuthorization{
        id: Ecto.UUID.generate(),
        initiating_device_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate()
      }

      assert Cache.Gateway.reauthorize_deleted_policy_authorization(%{}, pa) ==
               {:error, :not_found}
    end

    test "returns :not_found when the inner policy_authorization id is missing" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Cache.Gateway.put(%{}, client_id, dump!(resource_id), paid, expires_at)

      pa = %PolicyAuthorization{
        id: Ecto.UUID.generate(),
        initiating_device_id: client_id,
        resource_id: resource_id
      }

      assert Cache.Gateway.reauthorize_deleted_policy_authorization(cache, pa) ==
               {:error, :not_found}
    end

    test "returns the remaining max expiration when other authorizations exist" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid_a = Ecto.UUID.generate()
      paid_b = Ecto.UUID.generate()
      now = DateTime.utc_now()
      exp_a = DateTime.add(now, 60, :second)
      exp_b = DateTime.add(now, 3600, :second)

      cache =
        %{}
        |> Cache.Gateway.put(client_id, dump!(resource_id), paid_a, exp_a)
        |> Cache.Gateway.put(client_id, dump!(resource_id), paid_b, exp_b)

      pa = %PolicyAuthorization{
        id: paid_a,
        initiating_device_id: client_id,
        resource_id: resource_id
      }

      assert {:ok, expires_at_unix, updated} =
               Cache.Gateway.reauthorize_deleted_policy_authorization(cache, pa)

      assert expires_at_unix == DateTime.to_unix(exp_b, :second)
      assert map_size(updated) == 1
    end

    test "drops expired siblings and returns max of fresh remaining" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid_target = Ecto.UUID.generate()
      paid_stale = Ecto.UUID.generate()
      paid_fresh = Ecto.UUID.generate()
      now = DateTime.utc_now()
      exp_target = DateTime.add(now, 60, :second)
      exp_stale = DateTime.add(now, -60, :second)
      exp_fresh = DateTime.add(now, 3600, :second)

      cache =
        %{}
        |> Cache.Gateway.put(client_id, dump!(resource_id), paid_target, exp_target)
        |> Cache.Gateway.put(client_id, dump!(resource_id), paid_stale, exp_stale)
        |> Cache.Gateway.put(client_id, dump!(resource_id), paid_fresh, exp_fresh)

      pa = %PolicyAuthorization{
        id: paid_target,
        initiating_device_id: client_id,
        resource_id: resource_id
      }

      assert {:ok, expires_at_unix, updated} =
               Cache.Gateway.reauthorize_deleted_policy_authorization(cache, pa)

      assert expires_at_unix == DateTime.to_unix(exp_fresh, :second)
      key = {dump!(client_id), dump!(resource_id)}
      assert %{^key => paid_map} = updated
      assert map_size(paid_map) == 1
      assert Map.has_key?(paid_map, dump!(paid_fresh))
      refute Map.has_key?(paid_map, dump!(paid_stale))
    end

    test "treats all-expired siblings as last_policy_authorization_removed" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid_target = Ecto.UUID.generate()
      paid_stale = Ecto.UUID.generate()
      now = DateTime.utc_now()
      exp_target = DateTime.add(now, 60, :second)
      exp_stale = DateTime.add(now, -60, :second)

      cache =
        %{}
        |> Cache.Gateway.put(client_id, dump!(resource_id), paid_target, exp_target)
        |> Cache.Gateway.put(client_id, dump!(resource_id), paid_stale, exp_stale)

      pa = %PolicyAuthorization{
        id: paid_target,
        account_id: Ecto.UUID.generate(),
        initiating_device_id: client_id,
        receiving_device_id: Ecto.UUID.generate(),
        resource_id: resource_id,
        token_id: Ecto.UUID.generate(),
        expires_at: DateTime.utc_now() |> DateTime.add(60, :second)
      }

      assert {:error, :unauthorized, updated} =
               Cache.Gateway.reauthorize_deleted_policy_authorization(cache, pa)

      key = {dump!(client_id), dump!(resource_id)}
      refute Map.has_key?(updated, key)
    end

    test "creates a new policy_authorization when another conforming policy exists" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      identity_fixture(actor: actor, account: account)
      group_a = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group_a)
      group_b = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group_b)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      client = client_fixture(account: account, actor: actor)

      auth_provider = email_otp_provider_fixture(account: account).auth_provider

      token =
        client_token_fixture(
          account: account,
          actor: actor,
          auth_provider: auth_provider
        )

      client_session_fixture(account: account, actor: actor, client: client, token: token)

      resource = resource_fixture(account: account, site: site)

      policy_a = policy_fixture(account: account, group: group_a, resource: resource)
      policy_fixture(account: account, group: group_b, resource: resource)

      pa =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          gateway: gateway,
          client: client,
          resource: resource,
          group: group_a,
          policy: policy_a,
          token: token
        )

      cache = Cache.Gateway.hydrate(gateway)

      Portal.Repo.delete!(policy_a)

      assert {:ok, expires_at_unix, updated} =
               Cache.Gateway.reauthorize_deleted_policy_authorization(cache, pa)

      assert is_integer(expires_at_unix)
      key = {dump!(client.id), dump!(resource.id)}
      assert %{^key => paid_map} = updated
      assert map_size(paid_map) == 1
    end

    test "creates a new authorization for an Everyone-group policy without an explicit membership" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      identity_fixture(actor: actor, account: account)

      everyone_group =
        %Portal.Group{
          account_id: account.id,
          name: "Everyone",
          type: :managed,
          idp_id: nil
        }
        |> Portal.Repo.insert!()
        |> Portal.Repo.preload(:account)

      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      client = client_fixture(account: account, actor: actor)

      auth_provider = email_otp_provider_fixture(account: account).auth_provider

      token =
        client_token_fixture(
          account: account,
          actor: actor,
          auth_provider: auth_provider
        )

      client_session_fixture(account: account, actor: actor, client: client, token: token)

      resource = resource_fixture(account: account, site: site)

      everyone_policy =
        policy_fixture(account: account, group: everyone_group, resource: resource)

      pa =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          gateway: gateway,
          client: client,
          resource: resource,
          group: everyone_group,
          policy: everyone_policy,
          token: token
        )

      cache = Cache.Gateway.hydrate(gateway)

      # Remove the auto-created membership so the reauth flow falls into the
      # Everyone-group nil-membership branch.
      Portal.Repo.delete_all(
        from(m in Portal.Membership,
          where: m.account_id == ^account.id and m.group_id == ^everyone_group.id
        )
      )

      assert {:ok, expires_at_unix, updated} =
               Cache.Gateway.reauthorize_deleted_policy_authorization(cache, pa)

      assert is_integer(expires_at_unix)
      key = {dump!(client.id), dump!(resource.id)}
      assert %{^key => paid_map} = updated
      assert map_size(paid_map) == 1
    end

    test "returns :unauthorized when the last authorization is removed and reauth fails" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      client = client_fixture(account: account, actor: actor)
      resource = resource_fixture(account: account, site: site)
      policy = policy_fixture(account: account, group: group, resource: resource)

      pa =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          gateway: gateway,
          client: client,
          resource: resource,
          group: group,
          policy: policy
        )

      # Hydrate cache while the authorization still exists.
      cache = Cache.Gateway.hydrate(gateway)

      # Now delete the policy (cascading to delete the authorization in DB) — reauth attempt
      # should fail because no other policy grants access.
      Portal.Repo.delete!(policy)

      assert {:error, :unauthorized, updated} =
               Cache.Gateway.reauthorize_deleted_policy_authorization(cache, pa)

      key = {dump!(client.id), dump!(resource.id)}
      refute Map.has_key?(updated, key)
    end

    test "returns :unauthorized when all replacement policies have non-conforming conditions" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      identity_fixture(actor: actor, account: account)
      group_a = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group_a)
      group_b = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: group_b)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      client = client_fixture(account: account, actor: actor)

      auth_provider = email_otp_provider_fixture(account: account).auth_provider

      token =
        client_token_fixture(
          account: account,
          actor: actor,
          auth_provider: auth_provider
        )

      client_session_fixture(account: account, actor: actor, client: client, token: token)

      resource = resource_fixture(account: account, site: site)

      policy_a = policy_fixture(account: account, group: group_a, resource: resource)

      # Replacement policy with a condition that won't match (remote_ip restricted to
      # 0.0.0.0/32, but the client_session_fixture defaults to 100.64.0.1).
      policy_fixture(
        account: account,
        group: group_b,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip,
            operator: :is_in_cidr,
            values: ["0.0.0.0/32"]
          }
        ]
        )

      pa =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          gateway: gateway,
          client: client,
          resource: resource,
          group: group_a,
          policy: policy_a,
          token: token
        )

      cache = Cache.Gateway.hydrate(gateway)

      Portal.Repo.delete!(policy_a)

      assert {:error, :unauthorized, _updated} =
               Cache.Gateway.reauthorize_deleted_policy_authorization(cache, pa)
    end
  end
end
