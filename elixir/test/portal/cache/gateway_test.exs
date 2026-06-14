defmodule Portal.Cache.GatewayTest do
  use Portal.DataCase, async: true

  alias Portal.Cache

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.IdentityFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.SiteFixtures

  import Ecto.UUID, only: [dump!: 1]

  describe "hydrate/1" do
    test "returns an empty cache when there are no policy_authorizations" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      assert Cache.Gateway.hydrate(gateway) == %{}
    end

    test "loads matching policy_authorizations into the cache keyed by id" do
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

      key = dump!(policy_authorization.id)

      assert %{^key => entry} = cache

      assert entry ==
               {dump!(client.id), dump!(policy_authorization.resource_id),
                dump!(policy_authorization.policy_id),
                DateTime.to_unix(policy_authorization.expires_at, :second)}
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

  describe "put/6" do
    test "inserts a new entry keyed by policy_authorization id" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Cache.Gateway.put(%{}, pa_id, client_id, resource_id, policy_id, expires_at)

      key = dump!(pa_id)

      assert %{^key => entry} = cache

      assert entry ==
               {dump!(client_id), dump!(resource_id), dump!(policy_id),
                DateTime.to_unix(expires_at, :second)}
    end
  end

  describe "delete/2" do
    test "returns :error when the policy_authorization is not in the cache" do
      assert Cache.Gateway.delete(%{}, Ecto.UUID.generate()) == :error
    end

    test "returns the pair, expiration and updated cache, removing the entry" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Cache.Gateway.put(%{}, pa_id, client_id, resource_id, policy_id, expires_at)

      assert {:ok, ^client_id, ^resource_id, expires_at_unix, updated} =
               Cache.Gateway.delete(cache, pa_id)

      assert expires_at_unix == DateTime.to_unix(expires_at, :second)
      assert updated == %{}
    end

    test "only removes the targeted authorization for a shared pair" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      pa_id_a = Ecto.UUID.generate()
      pa_id_b = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache =
        %{}
        |> Cache.Gateway.put(pa_id_a, client_id, resource_id, Ecto.UUID.generate(), expires_at)
        |> Cache.Gateway.put(pa_id_b, client_id, resource_id, Ecto.UUID.generate(), expires_at)

      assert {:ok, ^client_id, ^resource_id, _exp, updated} = Cache.Gateway.delete(cache, pa_id_a)

      assert Map.has_key?(updated, dump!(pa_id_b))
      refute Map.has_key?(updated, dump!(pa_id_a))
    end
  end

  describe "prune/1" do
    test "drops expired authorizations" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expired = DateTime.utc_now() |> DateTime.add(-3600, :second)

      cache = Cache.Gateway.put(%{}, pa_id, client_id, resource_id, policy_id, expired)

      assert Cache.Gateway.prune(cache) == %{}
    end

    test "keeps unexpired authorizations" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache = Cache.Gateway.put(%{}, pa_id, client_id, resource_id, policy_id, expires_at)

      assert Cache.Gateway.prune(cache) == cache
    end
  end

  describe "has_resource?/2" do
    test "returns true when the resource is present" do
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      pa_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)
      cache = Cache.Gateway.put(%{}, pa_id, client_id, resource_id, policy_id, expires_at)

      assert Cache.Gateway.has_resource?(cache, resource_id)
    end

    test "returns false when the resource is not present" do
      refute Cache.Gateway.has_resource?(%{}, Ecto.UUID.generate())
    end
  end

  describe "all_pairs_for_resource/2" do
    test "returns matching {client, resource} pairs deduplicated" do
      resource_id = Ecto.UUID.generate()
      client_a = Ecto.UUID.generate()
      client_b = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      cache =
        %{}
        |> Cache.Gateway.put(Ecto.UUID.generate(), client_a, resource_id, policy_id, expires_at)
        |> Cache.Gateway.put(Ecto.UUID.generate(), client_a, resource_id, policy_id, expires_at)
        |> Cache.Gateway.put(Ecto.UUID.generate(), client_b, resource_id, policy_id, expires_at)

      pairs = Cache.Gateway.all_pairs_for_resource(cache, resource_id)

      assert Enum.sort(pairs) ==
               Enum.sort([{client_a, resource_id}, {client_b, resource_id}])
    end
  end
end
