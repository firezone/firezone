defmodule Portal.Cache.GatewayTest do
  use Portal.DataCase, async: true

  alias Portal.Cache

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.IdentityFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  import Ecto.UUID, only: [dump!: 1]

  describe "hydrate/2" do
    test "leaves out authorizations through a device pool with device_pools: false" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      pool = all_devices_pool_resource_fixture(account: account)

      through_pool = policy_authorization_fixture(account: account, gateway: gateway, resource: pool)
      to_resource = policy_authorization_fixture(account: account, gateway: gateway, site: site)

      pool_key = {dump!(through_pool.initiating_device_id), dump!(pool.id)}
      resource_key = {dump!(to_resource.initiating_device_id), dump!(to_resource.resource_id)}

      assert gateway |> Cache.Gateway.hydrate() |> Map.keys() |> Enum.sort() == Enum.sort([pool_key, resource_key])
      assert gateway |> Cache.Gateway.hydrate(device_pools: false) |> Map.keys() == [resource_key]
    end
  end

  describe "hydrate/1" do
    test "returns an empty cache when there are no policy_authorizations" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      assert Cache.Gateway.hydrate(gateway) == %{}
    end

    test "loads a policy_authorization keyed by {client, resource}" do
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

      assert %{^key => entry} = cache

      assert entry ==
               {dump!(policy_authorization.id),
                DateTime.to_unix(policy_authorization.expires_at, :second)}
    end

    test "keeps the longest-expiring authorization when a pair has more than one" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      identity_fixture(actor: actor, account: account)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      client = client_fixture(account: account, actor: actor)

      now = DateTime.utc_now()

      shorter =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          gateway: gateway,
          client: client,
          expires_at: DateTime.add(now, 3600, :second)
        )

      preloaded = Portal.Repo.preload(shorter, [:resource, :policy])

      longer =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          gateway: gateway,
          client: client,
          resource: preloaded.resource,
          policy: preloaded.policy,
          expires_at: DateTime.add(now, 7200, :second)
        )

      cache = Cache.Gateway.hydrate(gateway)

      key = {dump!(client.id), dump!(longer.resource_id)}

      assert map_size(cache) == 1
      assert {pa_id_bytes, _exp} = cache[key]
      assert pa_id_bytes == dump!(longer.id)
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
end
