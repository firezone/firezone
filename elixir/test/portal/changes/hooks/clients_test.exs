defmodule Portal.Changes.Hooks.ClientsTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Devices
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.ResourceFixtures
  alias Portal.Changes.Change
  alias Portal.Device
  alias Portal.PG
  alias Portal.PubSub

  describe "insert/1" do
    test "broadcasts inserted client" do
      account = account_fixture()
      client = client_fixture(account: account)
      :ok = PubSub.Changes.subscribe(client.account_id, :devices)

      data = %{"id" => client.id, "type" => "client", "account_id" => client.account_id}

      assert :ok == on_insert(0, data)
      assert_receive %Change{op: :insert, struct: %Device{} = inserted_client, lsn: 0}
      assert inserted_client.id == client.id
    end
  end

  describe "update/2" do
    test "update broadcasts updated client" do
      account = account_fixture()
      client = client_fixture(account: account)
      :ok = PubSub.Changes.subscribe(client.account_id, :devices)

      old_data = %{"id" => client.id, "name" => "Old Name", "account_id" => client.account_id}
      data = %{"id" => client.id, "name" => "New Name", "account_id" => client.account_id}

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %Device{} = old_client,
        struct: %Device{} = new_client,
        lsn: 0
      }

      assert old_client.name == "Old Name"
      assert new_client.name == "New Name"
      assert new_client.id == client.id
    end

    test "does not broadcast updates that only touch latest-session columns" do
      account = account_fixture()
      client = client_fixture(account: account)
      :ok = PubSub.Changes.subscribe(client.account_id, :devices)

      old_data = %{
        "id" => client.id,
        "account_id" => client.account_id,
        "name" => client.name,
        "last_seen_at" => nil
      }

      data = %{
        "id" => client.id,
        "account_id" => client.account_id,
        "name" => client.name,
        "last_seen_at" => "2026-07-20T00:00:00Z"
      }

      assert :ok == on_update(0, old_data, data)
      refute_receive %Change{op: :update}
    end

    test "update unverifies client and deletes associated policy authorizations" do
      account = account_fixture()
      client = client_fixture(account: account, verified_at: DateTime.utc_now())
      :ok = PubSub.Changes.subscribe(client.account_id, :devices)

      old_data = %{
        "id" => client.id,
        "type" => "client",
        "verified_at" => "2023-10-01T00:00:00Z",
        "account_id" => client.account_id
      }

      data = %{
        "id" => client.id,
        "type" => "client",
        "verified_at" => nil,
        "account_id" => client.account_id
      }

      policy_authorization =
        policy_authorization_fixture(client: client, account: account)

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %Device{},
        struct: %Device{} = new_client,
        lsn: 0
      }

      assert is_nil(new_client.verified_at)
      assert new_client.id == client.id
      refute Repo.get_by(Portal.PolicyAuthorization, id: policy_authorization.id)
    end

    test "update unverifies client and keeps the authorizations toward it as a pool member" do
      account = account_fixture()
      client = client_fixture(account: account, verified_at: DateTime.utc_now())
      initiator = client_fixture(account: account)
      pool = all_devices_pool_resource_fixture(account: account)

      old_data = %{
        "id" => client.id,
        "type" => "client",
        "verified_at" => "2023-10-01T00:00:00Z",
        "account_id" => client.account_id
      }

      data = Map.put(old_data, "verified_at", nil)

      inbound =
        policy_authorization_fixture(account: account, resource: pool, client: initiator, gateway: client)

      assert :ok == on_update(0, old_data, data)
      assert Repo.get_by(Portal.PolicyAuthorization, id: inbound.id)
    end
  end

  describe "update/2 with a rotated public key" do
    setup do
      account = account_fixture()
      client = client_fixture(account: account)
      gateway = gateway_fixture(account: account)

      old_data = %{
        "id" => client.id,
        "type" => "client",
        "account_id" => account.id,
        "public_key" => generate_public_key(),
        "last_seen_at" => "2026-10-01T00:00:00Z"
      }

      %{account: account, client: client, gateway: gateway, old_data: old_data}
    end

    test "deletes the prior session's authorizations and tells the connected peers", %{
      account: account,
      client: client,
      gateway: gateway,
      old_data: old_data
    } do
      PG.register(gateway.id)
      :ok = PubSub.Changes.subscribe(account.id, :devices)

      authorization =
        policy_authorization_fixture(account: account, client: client, gateway: gateway)

      assert :ok == on_update(0, old_data, rotated(old_data))

      assert_receive {:pubkey_changed, client_id}
      assert client_id == client.id
      refute Repo.get_by(Portal.PolicyAuthorization, id: authorization.id)
      refute_receive %Change{op: :update}
    end

    test "tells a peer once however many authorizations it held", %{
      account: account,
      client: client,
      gateway: gateway,
      old_data: old_data
    } do
      PG.register(gateway.id)

      for _ <- 1..2 do
        policy_authorization_fixture(account: account, client: client, gateway: gateway)
      end

      assert :ok == on_update(0, old_data, rotated(old_data))

      assert_receive {:pubkey_changed, _client_id}
      refute_receive {:pubkey_changed, _client_id}
    end

    test "tells the initiating peer when the rotated client was the receiver", %{
      account: account,
      client: client,
      old_data: old_data
    } do
      initiator = client_fixture(account: account)
      pool = all_devices_pool_resource_fixture(account: account)
      PG.register(initiator.id)

      inbound =
        policy_authorization_fixture(
          account: account,
          resource: pool,
          client: initiator,
          gateway: client
        )

      assert :ok == on_update(0, old_data, rotated(old_data))

      assert_receive {:pubkey_changed, client_id}
      assert client_id == client.id
      refute Repo.get_by(Portal.PolicyAuthorization, id: inbound.id)
    end

    test "keeps the authorizations the new session created", %{
      account: account,
      client: client,
      gateway: gateway,
      old_data: old_data
    } do
      PG.register(gateway.id)

      authorization =
        policy_authorization_fixture(account: account, client: client, gateway: gateway)

      connected_at = DateTime.add(DateTime.utc_now(), -60, :second)
      data = rotated(old_data, connected_at)

      assert :ok == on_update(0, old_data, data)

      refute_receive {:pubkey_changed, _client_id}
      assert Repo.get_by(Portal.PolicyAuthorization, id: authorization.id)
    end

    test "leaves expired authorizations to the reaper", %{
      account: account,
      client: client,
      gateway: gateway,
      old_data: old_data
    } do
      PG.register(gateway.id)

      expired =
        expired_policy_authorization_fixture(account: account, client: client, gateway: gateway)

      assert :ok == on_update(0, old_data, rotated(old_data))

      refute_receive {:pubkey_changed, _client_id}
      assert Repo.get_by(Portal.PolicyAuthorization, id: expired.id)
    end

    test "does nothing when the key is set for the first time", %{
      account: account,
      client: client,
      gateway: gateway,
      old_data: old_data
    } do
      PG.register(gateway.id)

      authorization =
        policy_authorization_fixture(account: account, client: client, gateway: gateway)

      old_data = Map.put(old_data, "public_key", nil)

      assert :ok == on_update(0, old_data, rotated(old_data))

      refute_receive {:pubkey_changed, _client_id}
      assert Repo.get_by(Portal.PolicyAuthorization, id: authorization.id)
    end

    test "does nothing when the key stays the same", %{
      account: account,
      client: client,
      gateway: gateway,
      old_data: old_data
    } do
      PG.register(gateway.id)

      authorization =
        policy_authorization_fixture(account: account, client: client, gateway: gateway)

      data = Map.put(rotated(old_data), "public_key", old_data["public_key"])

      assert :ok == on_update(0, old_data, data)

      refute_receive {:pubkey_changed, _client_id}
      assert Repo.get_by(Portal.PolicyAuthorization, id: authorization.id)
    end
  end

  # The flushed row of a session that connected at `connected_at` with a new key.
  defp rotated(old_data, connected_at \\ DateTime.add(DateTime.utc_now(), 1, :second)) do
    Map.merge(old_data, %{
      "public_key" => generate_public_key(),
      "last_seen_at" => DateTime.to_iso8601(connected_at)
    })
  end

  describe "delete/1" do
    test "broadcasts deleted client" do
      account = account_fixture()
      client = client_fixture(account: account)
      :ok = PubSub.Changes.subscribe(client.account_id, :devices)

      old_data = %{"id" => client.id, "type" => "client", "account_id" => client.account_id}

      assert :ok == on_delete(0, old_data)
      assert_receive %Change{op: :delete, old_struct: %Device{} = deleted_client, lsn: 0}
      assert deleted_client.id == client.id
    end

    test "removes the client from the pools that list it" do
      account = account_fixture()
      client = client_fixture(account: account)
      other = client_fixture(account: account)

      pool =
        Portal.ResourceFixtures.device_pool_resource_fixture(account: account, devices: [client, other])

      old_data = %{"id" => client.id, "type" => "client", "account_id" => client.account_id}

      assert :ok == on_delete(0, old_data)

      pool = Repo.get_by!(Portal.Resource, id: pool.id)

      assert Portal.Resource.DeviceMembershipCriteria.device_ids(pool.device_membership_criteria) ==
               {:ok, [other.id]}
    end

    test "leaves the pools that do not list their devices untouched" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      group = group_fixture(account: account)

      pools = [
        own_devices_pool_resource_fixture(account: account),
        all_devices_pool_resource_fixture(account: account),
        actor_group_pool_resource_fixture(account: account, group: group)
      ]

      old_data = %{"id" => client.id, "type" => "client", "account_id" => client.account_id}

      assert :ok == on_delete(0, old_data)

      for pool <- pools do
        assert Repo.get_by!(Portal.Resource, id: pool.id).device_membership_criteria ==
                 pool.device_membership_criteria
      end
    end
  end
end
