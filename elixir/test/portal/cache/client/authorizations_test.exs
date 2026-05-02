defmodule Portal.Cache.Client.AuthorizationsTest do
  use Portal.DataCase, async: true

  alias Portal.Cache.Client.Authorizations
  alias Portal.PolicyAuthorization

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.IdentityFixtures
  import Portal.PolicyAuthorizationFixtures

  import Ecto.UUID, only: [dump!: 1]

  describe "hydrate/1" do
    test "returns an empty cache when there are no policy_authorizations" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      assert Authorizations.hydrate(client) == %{}
    end

    test "loads matching policy_authorizations into cache keyed by {client_id, resource_id}" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: actor)

      initiating_actor = actor_fixture(account: account)
      initiating_client = client_fixture(account: account, actor: initiating_actor)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          client: initiating_client,
          gateway: target_client
        )

      cache = Authorizations.hydrate(target_client)

      key = {dump!(initiating_client.id), dump!(policy_authorization.resource_id)}
      assert %{^key => paid_map} = cache
      assert Map.fetch!(paid_map, dump!(policy_authorization.id)) ==
               DateTime.to_unix(policy_authorization.expires_at, :second)
    end

    test "groups multiple policy_authorizations for the same {client, resource} pair" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: actor)

      initiating_actor = actor_fixture(account: account)
      initiating_client = client_fixture(account: account, actor: initiating_actor)

      pa1 =
        policy_authorization_fixture(
          account: account,
          client: initiating_client,
          gateway: target_client
        )

      preloaded = Portal.Repo.preload(pa1, [:resource, :policy])

      pa2 =
        policy_authorization_fixture(
          account: account,
          client: initiating_client,
          gateway: target_client,
          resource: preloaded.resource,
          policy: preloaded.policy
        )

      cache = Authorizations.hydrate(target_client)
      key = {dump!(initiating_client.id), dump!(pa1.resource_id)}
      assert %{^key => paid_map} = cache
      assert map_size(paid_map) == 2
      assert Map.has_key?(paid_map, dump!(pa1.id))
      assert Map.has_key?(paid_map, dump!(pa2.id))
    end

    test "ignores expired policy_authorizations" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: actor)

      initiating_actor = actor_fixture(account: account)
      initiating_client = client_fixture(account: account, actor: initiating_actor)

      expired_policy_authorization_fixture(
        account: account,
        client: initiating_client,
        gateway: target_client
      )

      assert Authorizations.hydrate(target_client) == %{}
    end

    test "ignores policy_authorizations targeting other devices" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: actor)

      initiating_actor = actor_fixture(account: account)
      initiating_client = client_fixture(account: account, actor: initiating_actor)

      # Default fixture targets a gateway, not target_client
      policy_authorization_fixture(account: account, client: initiating_client)

      assert Authorizations.hydrate(target_client) == %{}
    end
  end

  describe "put/5" do
    test "inserts a new policy_authorization entry" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Authorizations.put(%{}, client_id, resource_id, paid, expires_at)

      key = {dump!(client_id), dump!(resource_id)}
      assert %{^key => paid_map} = cache
      assert Map.fetch!(paid_map, dump!(paid)) == DateTime.to_unix(expires_at, :second)
    end

    test "appends to an existing entry without losing prior policy_authorizations" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid_a = Ecto.UUID.generate()
      paid_b = Ecto.UUID.generate()
      now = DateTime.utc_now()
      exp_a = DateTime.add(now, 60, :second)
      exp_b = DateTime.add(now, 120, :second)

      cache =
        %{}
        |> Authorizations.put(client_id, resource_id, paid_a, exp_a)
        |> Authorizations.put(client_id, resource_id, paid_b, exp_b)

      key = {dump!(client_id), dump!(resource_id)}
      assert %{^key => paid_map} = cache
      assert map_size(paid_map) == 2
    end
  end

  describe "prune/1" do
    test "drops expired entries and removes client/resource keys with no remaining authorizations" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expired = DateTime.utc_now() |> DateTime.add(-3600, :second)

      cache = Authorizations.put(%{}, client_id, resource_id, paid, expired)

      assert Authorizations.prune(cache) == %{}
    end

    test "keeps entries that are still valid" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Authorizations.put(%{}, client_id, resource_id, paid, expires_at)

      assert Authorizations.prune(cache) == cache
    end

    test "preserves valid policy_authorizations on a key with mixed expirations" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid_valid = Ecto.UUID.generate()
      paid_expired = Ecto.UUID.generate()
      now = DateTime.utc_now()

      cache =
        %{}
        |> Authorizations.put(client_id, resource_id, paid_valid, DateTime.add(now, 3600, :second))
        |> Authorizations.put(client_id, resource_id, paid_expired, DateTime.add(now, -3600, :second))

      pruned = Authorizations.prune(cache)
      key = {dump!(client_id), dump!(resource_id)}
      assert %{^key => paid_map} = pruned
      assert map_size(paid_map) == 1
      assert Map.has_key?(paid_map, dump!(paid_valid))
      refute Map.has_key?(paid_map, dump!(paid_expired))
    end
  end

  describe "reauthorize_deleted_policy_authorization/2" do
    test "returns :not_found when the {client, resource} pair is not present" do
      pa = %PolicyAuthorization{
        id: Ecto.UUID.generate(),
        initiating_device_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate()
      }

      assert Authorizations.reauthorize_deleted_policy_authorization(%{}, pa) ==
               {:error, :not_found}
    end

    test "returns :not_found when the policy_authorization id is not in the entry" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Authorizations.put(%{}, client_id, resource_id, paid, expires_at)

      pa = %PolicyAuthorization{
        id: Ecto.UUID.generate(),
        initiating_device_id: client_id,
        resource_id: resource_id
      }

      assert Authorizations.reauthorize_deleted_policy_authorization(cache, pa) ==
               {:error, :not_found}
    end

    test "returns the remaining max expiration when other cached authorizations exist" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid_a = Ecto.UUID.generate()
      paid_b = Ecto.UUID.generate()
      now = DateTime.utc_now()
      exp_a = DateTime.add(now, 60, :second)
      exp_b = DateTime.add(now, 3600, :second)

      cache =
        %{}
        |> Authorizations.put(client_id, resource_id, paid_a, exp_a)
        |> Authorizations.put(client_id, resource_id, paid_b, exp_b)

      pa = %PolicyAuthorization{
        id: paid_a,
        initiating_device_id: client_id,
        resource_id: resource_id
      }

      assert {:ok, expires_at_unix, updated} =
               Authorizations.reauthorize_deleted_policy_authorization(cache, pa)

      assert expires_at_unix == DateTime.to_unix(exp_b, :second)
      key = {dump!(client_id), dump!(resource_id)}
      assert %{^key => paid_map} = updated
      assert map_size(paid_map) == 1
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
        |> Authorizations.put(client_id, resource_id, paid_target, exp_target)
        |> Authorizations.put(client_id, resource_id, paid_stale, exp_stale)
        |> Authorizations.put(client_id, resource_id, paid_fresh, exp_fresh)

      pa = %PolicyAuthorization{
        id: paid_target,
        initiating_device_id: client_id,
        resource_id: resource_id
      }

      assert {:ok, expires_at_unix, updated} =
               Authorizations.reauthorize_deleted_policy_authorization(cache, pa)

      assert expires_at_unix == DateTime.to_unix(exp_fresh, :second)
      key = {dump!(client_id), dump!(resource_id)}
      assert %{^key => paid_map} = updated
      assert map_size(paid_map) == 1
      assert Map.has_key?(paid_map, dump!(paid_fresh))
      refute Map.has_key?(paid_map, dump!(paid_stale))
    end

    test "treats all-expired siblings as last_policy_authorization_removed" do
      account = account_fixture()
      target_actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: target_actor)

      initiating_actor = actor_fixture(account: account)
      initiating_client = client_fixture(account: account, actor: initiating_actor)

      pa = %PolicyAuthorization{
        id: Ecto.UUID.generate(),
        account_id: account.id,
        initiating_device_id: initiating_client.id,
        receiving_device_id: target_client.id,
        resource_id: Ecto.UUID.generate(),
        token_id: Ecto.UUID.generate(),
        expires_at: DateTime.utc_now() |> DateTime.add(60, :second)
      }

      stale_at = DateTime.utc_now() |> DateTime.add(-60, :second)

      cache =
        %{}
        |> Authorizations.put(
          initiating_client.id,
          pa.resource_id,
          pa.id,
          DateTime.utc_now() |> DateTime.add(60, :second)
        )
        |> Authorizations.put(
          initiating_client.id,
          pa.resource_id,
          Ecto.UUID.generate(),
          stale_at
        )

      assert {:error, :unauthorized, updated} =
               Authorizations.reauthorize_deleted_policy_authorization(cache, pa)

      key = {dump!(initiating_client.id), dump!(pa.resource_id)}
      refute Map.has_key?(updated, key)
    end

    test "creates a new policy_authorization when another conforming policy exists" do
      account = account_fixture()
      target_actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: target_actor)

      initiating_actor = actor_fixture(account: account)
      identity_fixture(actor: initiating_actor, account: account)
      initiating_client = client_fixture(account: account, actor: initiating_actor)

      group_a = Portal.GroupFixtures.group_fixture(account: account)
      group_b = Portal.GroupFixtures.group_fixture(account: account)

      Portal.MembershipFixtures.membership_fixture(
        account: account,
        actor: initiating_actor,
        group: group_a
      )

      Portal.MembershipFixtures.membership_fixture(
        account: account,
        actor: initiating_actor,
        group: group_b
      )

      auth_provider = Portal.AuthProviderFixtures.email_otp_provider_fixture(account: account).auth_provider

      token =
        Portal.TokenFixtures.client_token_fixture(
          account: account,
          actor: initiating_actor,
          auth_provider: auth_provider
        )

      Portal.ClientSessionFixtures.client_session_fixture(
        account: account,
        actor: initiating_actor,
        client: initiating_client,
        token: token
      )

      pool_resource =
        Portal.ResourceFixtures.static_device_pool_resource_fixture(
          account: account,
          clients: [target_client]
        )

      policy_a =
        Portal.PolicyFixtures.policy_fixture(account: account, group: group_a, resource: pool_resource)

      Portal.PolicyFixtures.policy_fixture(account: account, group: group_b, resource: pool_resource)

      pa =
        policy_authorization_fixture(
          account: account,
          actor: initiating_actor,
          client: initiating_client,
          gateway: target_client,
          resource: pool_resource,
          group: group_a,
          policy: policy_a,
          token: token
        )

      cache = Authorizations.hydrate(target_client)

      Portal.Repo.delete!(policy_a)

      assert {:ok, expires_at_unix, updated} =
               Authorizations.reauthorize_deleted_policy_authorization(cache, pa)

      assert is_integer(expires_at_unix)
      key = {dump!(initiating_client.id), dump!(pool_resource.id)}
      assert %{^key => paid_map} = updated
      assert map_size(paid_map) == 1
    end

    test "returns :unauthorized when the last authorization is removed and reauth fails" do
      account = account_fixture()
      target_actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: target_actor)

      initiating_actor = actor_fixture(account: account)
      identity_fixture(actor: initiating_actor, account: account)
      initiating_client = client_fixture(account: account, actor: initiating_actor)

      group = Portal.GroupFixtures.group_fixture(account: account)

      Portal.MembershipFixtures.membership_fixture(
        account: account,
        actor: initiating_actor,
        group: group
      )

      pool_resource =
        Portal.ResourceFixtures.static_device_pool_resource_fixture(
          account: account,
          clients: [target_client]
        )

      policy =
        Portal.PolicyFixtures.policy_fixture(
          account: account,
          group: group,
          resource: pool_resource
        )

      pa =
        policy_authorization_fixture(
          account: account,
          actor: initiating_actor,
          client: initiating_client,
          gateway: target_client,
          resource: pool_resource,
          group: group,
          policy: policy
        )

      cache = Authorizations.hydrate(target_client)

      Portal.Repo.delete!(policy)

      assert {:error, :unauthorized, updated} =
               Authorizations.reauthorize_deleted_policy_authorization(cache, pa)

      key = {dump!(initiating_client.id), dump!(pool_resource.id)}
      refute Map.has_key?(updated, key)
    end
  end

  describe "has_resource?/2" do
    test "returns true when the cache holds at least one entry for the resource" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Authorizations.put(%{}, client_id, resource_id, paid, expires_at)

      assert Authorizations.has_resource?(cache, resource_id)
    end

    test "returns false when the resource is not in the cache" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Authorizations.put(%{}, client_id, resource_id, paid, expires_at)

      refute Authorizations.has_resource?(cache, Ecto.UUID.generate())
    end
  end

  describe "all_pairs_for_resource/2" do
    test "returns every {client, resource} pair matching the resource" do
      resource_id = Ecto.UUID.generate()
      other_resource_id = Ecto.UUID.generate()
      client_a = Ecto.UUID.generate()
      client_b = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache =
        %{}
        |> Authorizations.put(client_a, resource_id, Ecto.UUID.generate(), expires_at)
        |> Authorizations.put(client_b, resource_id, Ecto.UUID.generate(), expires_at)
        |> Authorizations.put(client_a, other_resource_id, Ecto.UUID.generate(), expires_at)

      pairs = Authorizations.all_pairs_for_resource(cache, resource_id)

      assert Enum.sort(pairs) ==
               Enum.sort([{client_a, resource_id}, {client_b, resource_id}])
    end

    test "returns an empty list when no pairs match the resource" do
      cache =
        Authorizations.put(
          %{},
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      assert Authorizations.all_pairs_for_resource(cache, Ecto.UUID.generate()) == []
    end
  end
end
