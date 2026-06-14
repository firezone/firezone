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

    test "loads a policy_authorization keyed by {client, resource}" do
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

      assert %{^key => entry} = cache

      assert entry ==
               {dump!(policy_authorization.id), dump!(policy_authorization.policy_id),
                DateTime.to_unix(policy_authorization.expires_at, :second)}
    end

    test "keeps the longest-expiring authorization when a pair has more than one" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: actor)

      initiating_actor = actor_fixture(account: account)
      initiating_client = client_fixture(account: account, actor: initiating_actor)

      now = DateTime.utc_now()

      shorter =
        policy_authorization_fixture(
          account: account,
          client: initiating_client,
          gateway: target_client,
          expires_at: DateTime.add(now, 3600, :second)
        )

      preloaded = Portal.Repo.preload(shorter, [:resource, :policy])

      longer =
        policy_authorization_fixture(
          account: account,
          client: initiating_client,
          gateway: target_client,
          resource: preloaded.resource,
          policy: preloaded.policy,
          expires_at: DateTime.add(now, 7200, :second)
        )

      cache = Authorizations.hydrate(target_client)

      key = {dump!(initiating_client.id), dump!(longer.resource_id)}

      assert map_size(cache) == 1
      assert {pa_id_bytes, _policy_id, _exp} = cache[key]
      assert pa_id_bytes == dump!(longer.id)
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
    test "inserts an entry keyed by {client, resource}" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Authorizations.put(%{}, pa_id, client_id, resource_id, policy_id, expires_at)

      key = {dump!(client_id), dump!(resource_id)}

      assert %{^key => entry} = cache

      assert entry ==
               {dump!(pa_id), dump!(policy_id), DateTime.to_unix(expires_at, :second)}
    end

    test "is last-one-wins: a newer authorization supersedes the previous for the same pair" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      pa_id_a = Ecto.UUID.generate()
      pa_id_b = Ecto.UUID.generate()

      cache =
        %{}
        |> Authorizations.put(
          pa_id_a,
          client_id,
          resource_id,
          Ecto.UUID.generate(),
          DateTime.add(now, 3600, :second)
        )
        |> Authorizations.put(
          pa_id_b,
          client_id,
          resource_id,
          Ecto.UUID.generate(),
          DateTime.add(now, 60, :second)
        )

      key = {dump!(client_id), dump!(resource_id)}

      assert map_size(cache) == 1
      assert {pa_id_bytes, _policy_id, _exp} = cache[key]
      assert pa_id_bytes == dump!(pa_id_b)
    end

    test "accepts already-dumped 16-byte binary ids (Cacheable resources)" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache =
        Authorizations.put(
          %{},
          dump!(pa_id),
          dump!(client_id),
          dump!(resource_id),
          dump!(policy_id),
          expires_at
        )

      key = {dump!(client_id), dump!(resource_id)}

      assert %{^key => entry} = cache

      assert entry ==
               {dump!(pa_id), dump!(policy_id), DateTime.to_unix(expires_at, :second)}

      assert Authorizations.has_resource?(cache, dump!(resource_id))
      assert {:ok, _exp, %{}} = Authorizations.delete(cache, dump!(pa_id), client_id, resource_id)
    end
  end

  describe "delete/4" do
    test "returns :error when the pair is not in the cache" do
      assert Authorizations.delete(
               %{},
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate()
             ) == :error
    end

    test "returns the expiration and removes the entry when it is the cached authorization" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Authorizations.put(%{}, pa_id, client_id, resource_id, policy_id, expires_at)

      assert {:ok, expires_at_unix, updated} =
               Authorizations.delete(cache, pa_id, client_id, resource_id)

      assert expires_at_unix == DateTime.to_unix(expires_at, :second)
      assert updated == %{}
    end

    test "is a no-op for a superseded authorization (different pa_id for the pair)" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      old_pa_id = Ecto.UUID.generate()
      current_pa_id = Ecto.UUID.generate()

      cache =
        %{}
        |> Authorizations.put(
          old_pa_id,
          client_id,
          resource_id,
          Ecto.UUID.generate(),
          DateTime.add(now, 3600, :second)
        )
        |> Authorizations.put(
          current_pa_id,
          client_id,
          resource_id,
          Ecto.UUID.generate(),
          DateTime.add(now, 3600, :second)
        )

      assert Authorizations.delete(cache, old_pa_id, client_id, resource_id) == :error

      key = {dump!(client_id), dump!(resource_id)}
      assert {pa_id_bytes, _policy_id, _exp} = cache[key]
      assert pa_id_bytes == dump!(current_pa_id)
    end
  end

  describe "prune/1" do
    test "drops expired entries" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expired = DateTime.utc_now() |> DateTime.add(-3600, :second)

      cache = Authorizations.put(%{}, pa_id, client_id, resource_id, policy_id, expired)

      assert Authorizations.prune(cache) == %{}
    end

    test "keeps entries that are still valid" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Authorizations.put(%{}, pa_id, client_id, resource_id, policy_id, expires_at)

      assert Authorizations.prune(cache) == cache
    end
  end

  describe "has_resource?/2" do
    test "returns true when the cache holds an entry for the resource" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Authorizations.put(%{}, pa_id, client_id, resource_id, policy_id, expires_at)

      assert Authorizations.has_resource?(cache, resource_id)
    end

    test "returns false when the resource is not in the cache" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Authorizations.put(%{}, pa_id, client_id, resource_id, policy_id, expires_at)

      refute Authorizations.has_resource?(cache, Ecto.UUID.generate())
    end
  end

  describe "all_pairs_for_resource/2" do
    test "returns every {client, resource} pair matching the resource" do
      resource_id = Ecto.UUID.generate()
      other_resource_id = Ecto.UUID.generate()
      client_a = Ecto.UUID.generate()
      client_b = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache =
        %{}
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
