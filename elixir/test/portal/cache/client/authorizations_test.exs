defmodule Portal.Cache.Client.AuthorizationsTest do
  use Portal.DataCase, async: true

  alias Portal.Cache.Client.Authorizations

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.PolicyAuthorizationFixtures

  import Ecto.UUID, only: [dump!: 1]

  describe "hydrate/1" do
    test "returns an empty cache when there are no policy_authorizations" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      assert Authorizations.hydrate(client) == %{}
    end

    test "loads matching policy_authorizations into the cache keyed by id" do
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

      key = dump!(policy_authorization.id)

      assert %{^key => entry} = cache

      assert entry ==
               {dump!(initiating_client.id), dump!(policy_authorization.resource_id),
                dump!(policy_authorization.policy_id),
                DateTime.to_unix(policy_authorization.expires_at, :second)}
    end

    test "keeps a separate entry per policy_authorization for the same pair" do
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

      assert map_size(cache) == 2
      assert Map.has_key?(cache, dump!(pa1.id))
      assert Map.has_key?(cache, dump!(pa2.id))
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

  describe "put/6" do
    test "inserts a new policy_authorization entry keyed by id" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Authorizations.put(%{}, paid, client_id, resource_id, policy_id, expires_at)

      key = dump!(paid)

      assert %{^key => entry} = cache

      assert entry ==
               {dump!(client_id), dump!(resource_id), dump!(policy_id),
                DateTime.to_unix(expires_at, :second)}
    end
  end

  describe "delete/2" do
    test "returns :error when the policy_authorization is not in the cache" do
      assert Authorizations.delete(%{}, Ecto.UUID.generate()) == :error
    end

    test "returns the pair, expiration and updated cache, removing the entry" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Authorizations.put(%{}, paid, client_id, resource_id, policy_id, expires_at)

      assert {:ok, ^client_id, ^resource_id, expires_at_unix, updated} =
               Authorizations.delete(cache, paid)

      assert expires_at_unix == DateTime.to_unix(expires_at, :second)
      assert updated == %{}
    end

    test "only removes the targeted authorization for a shared pair" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      paid_a = Ecto.UUID.generate()
      paid_b = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache =
        %{}
        |> Authorizations.put(paid_a, client_id, resource_id, Ecto.UUID.generate(), expires_at)
        |> Authorizations.put(paid_b, client_id, resource_id, Ecto.UUID.generate(), expires_at)

      assert {:ok, ^client_id, ^resource_id, _exp, updated} = Authorizations.delete(cache, paid_a)

      assert Map.has_key?(updated, dump!(paid_b))
      refute Map.has_key?(updated, dump!(paid_a))
    end
  end

  describe "prune/1" do
    test "drops expired entries" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expired = DateTime.utc_now() |> DateTime.add(-3600, :second)

      cache = Authorizations.put(%{}, paid, client_id, resource_id, policy_id, expired)

      assert Authorizations.prune(cache) == %{}
    end

    test "keeps entries that are still valid" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Authorizations.put(%{}, paid, client_id, resource_id, policy_id, expires_at)

      assert Authorizations.prune(cache) == cache
    end

    test "drops only the expired entries on a shared pair" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      paid_valid = Ecto.UUID.generate()
      paid_expired = Ecto.UUID.generate()
      now = DateTime.utc_now()

      cache =
        %{}
        |> Authorizations.put(
          paid_valid,
          client_id,
          resource_id,
          policy_id,
          DateTime.add(now, 3600, :second)
        )
        |> Authorizations.put(
          paid_expired,
          client_id,
          resource_id,
          policy_id,
          DateTime.add(now, -3600, :second)
        )

      pruned = Authorizations.prune(cache)

      assert map_size(pruned) == 1
      assert Map.has_key?(pruned, dump!(paid_valid))
      refute Map.has_key?(pruned, dump!(paid_expired))
    end
  end

  describe "has_resource?/2" do
    test "returns true when the cache holds at least one entry for the resource" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Authorizations.put(%{}, paid, client_id, resource_id, policy_id, expires_at)

      assert Authorizations.has_resource?(cache, resource_id)
    end

    test "returns false when the resource is not in the cache" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Authorizations.put(%{}, paid, client_id, resource_id, policy_id, expires_at)

      refute Authorizations.has_resource?(cache, Ecto.UUID.generate())
    end
  end

  describe "all_pairs_for_resource/2" do
    test "returns every {client, resource} pair matching the resource deduplicated" do
      resource_id = Ecto.UUID.generate()
      other_resource_id = Ecto.UUID.generate()
      client_a = Ecto.UUID.generate()
      client_b = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache =
        %{}
        |> Authorizations.put(Ecto.UUID.generate(), client_a, resource_id, policy_id, expires_at)
        |> Authorizations.put(Ecto.UUID.generate(), client_a, resource_id, policy_id, expires_at)
        |> Authorizations.put(Ecto.UUID.generate(), client_b, resource_id, policy_id, expires_at)
        |> Authorizations.put(
          Ecto.UUID.generate(),
          client_a,
          other_resource_id,
          policy_id,
          expires_at
        )

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
          Ecto.UUID.generate(),
          DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      assert Authorizations.all_pairs_for_resource(cache, Ecto.UUID.generate()) == []
    end
  end
end
