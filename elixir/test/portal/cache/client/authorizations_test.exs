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

      assert Authorizations.hydrate(client) == {%{}, %{}}
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

      {cache, _outbound} = Authorizations.hydrate(target_client)

      key = {dump!(initiating_client.id), dump!(policy_authorization.resource_id)}

      assert %{^key => entry} = cache

      assert entry ==
               {dump!(policy_authorization.id),
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

      {cache, _outbound} = Authorizations.hydrate(target_client)

      key = {dump!(initiating_client.id), dump!(longer.resource_id)}

      assert map_size(cache) == 1
      assert {pa_id_bytes, _exp} = cache[key]
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

      {inbound, _outbound} = Authorizations.hydrate(target_client)
      assert inbound == %{}
    end

    test "ignores policy_authorizations targeting other devices" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      target_client = client_fixture(account: account, actor: actor)

      initiating_actor = actor_fixture(account: account)
      initiating_client = client_fixture(account: account, actor: initiating_actor)

      # Default fixture targets a gateway, not target_client
      policy_authorization_fixture(account: account, client: initiating_client)

      {inbound, _outbound} = Authorizations.hydrate(target_client)
      assert inbound == %{}
    end

    test "loads an authorization to another client keyed by {receiving client, resource}" do
      account = account_fixture()
      initiating_client = client_fixture(account: account)
      target_client = client_fixture(account: account)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          client: initiating_client,
          gateway: target_client
        )

      {inbound, cache} = Authorizations.hydrate(initiating_client)

      assert inbound == %{}

      key = {dump!(target_client.id), dump!(policy_authorization.resource_id)}

      assert cache == %{
               key =>
                 {dump!(policy_authorization.id),
                  DateTime.to_unix(policy_authorization.expires_at, :second)}
             }
    end

    test "ignores outbound authorizations to gateways" do
      account = account_fixture()
      initiating_client = client_fixture(account: account)

      policy_authorization_fixture(account: account, client: initiating_client)

      assert Authorizations.hydrate(initiating_client) == {%{}, %{}}
    end

    test "keeps inbound authorizations out of the outbound cache" do
      account = account_fixture()
      client = client_fixture(account: account)
      peer_client = client_fixture(account: account)

      expired_policy_authorization_fixture(account: account, client: client, gateway: peer_client)
      policy_authorization_fixture(account: account, client: peer_client, gateway: client)

      {inbound, outbound} = Authorizations.hydrate(client)
      assert map_size(inbound) == 1
      assert outbound == %{}
    end
  end
end
