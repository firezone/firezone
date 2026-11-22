defmodule Portal.Changes.Hooks.GatewaysTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Devices
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.ResourceFixtures
  alias Portal.Changes.Change
  alias Portal.Device
  alias Portal.PubSub

  describe "insert/1" do
    test "broadcasts inserted gateway" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :devices)

      data = %{"id" => gateway.id, "type" => "gateway", "account_id" => account.id}

      assert :ok == on_insert(0, data)
      assert_receive %Change{op: :insert, struct: %Device{} = inserted_gateway, lsn: 0}
      assert inserted_gateway.id == gateway.id
    end
  end

  describe "update/2" do
    test "update returns :ok" do
      account = account_fixture()

      assert :ok =
               on_update(
                 0,
                 %{"id" => Ecto.UUID.generate(), "type" => "gateway", "account_id" => account.id},
                 %{"id" => Ecto.UUID.generate(), "type" => "gateway", "account_id" => account.id}
               )
    end

    test "broadcasts a gateway leaving /device/v1 and ends its pool authorizations only" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      initiator = client_fixture(account: account)
      pool = all_devices_pool_resource_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :devices)

      through_pool =
        policy_authorization_fixture(account: account, resource: pool, client: initiator, gateway: gateway)

      to_resource = policy_authorization_fixture(account: account, client: initiator, gateway: gateway)

      old_data = %{
        "id" => gateway.id,
        "type" => "gateway",
        "account_id" => account.id,
        "last_seen_device_v1" => true,
        "last_seen_at" => nil
      }

      data = %{old_data | "last_seen_device_v1" => false, "last_seen_at" => "2026-11-21T00:00:00Z"}

      assert :ok == on_update(0, old_data, data)
      assert_receive %Change{op: :update, struct: %Device{last_seen_device_v1: false}}
      refute Repo.get_by(Portal.PolicyAuthorization, id: through_pool.id)
      assert Repo.get_by(Portal.PolicyAuthorization, id: to_resource.id)
    end

    test "broadcasts a gateway joining /device/v1 and keeps its authorizations" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      pool = all_devices_pool_resource_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :devices)

      through_pool = policy_authorization_fixture(account: account, resource: pool, gateway: gateway)

      old_data = %{
        "id" => gateway.id,
        "type" => "gateway",
        "account_id" => account.id,
        "last_seen_device_v1" => false
      }

      assert :ok == on_update(0, old_data, %{old_data | "last_seen_device_v1" => true})
      assert_receive %Change{op: :update, struct: %Device{last_seen_device_v1: true}}
      assert Repo.get_by(Portal.PolicyAuthorization, id: through_pool.id)
    end

    test "does not broadcast a client changing protocol" do
      account = account_fixture()
      client = client_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :devices)

      old_data = %{
        "id" => client.id,
        "type" => "client",
        "account_id" => account.id,
        "last_seen_device_v1" => true
      }

      assert :ok == on_update(0, old_data, %{old_data | "last_seen_device_v1" => false})
      refute_receive %Change{op: :update}
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted gateway" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)

      :ok = PubSub.Changes.subscribe(account.id, :devices)

      old_data = %{
        "id" => gateway.id,
        "type" => "gateway",
        "account_id" => account.id,
        "name" => "Test Gateway"
      }

      assert :ok = on_delete(0, old_data)

      assert_receive %Change{
        op: :delete,
        old_struct: %Device{} = deleted_gateway,
        lsn: 0
      }

      assert deleted_gateway.id == gateway.id
    end

    test "removes the gateway from the pools that list it" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      pool = device_pool_resource_fixture(account: account, devices: [gateway])

      assert :ok = on_delete(0, %{"id" => gateway.id, "type" => "gateway", "account_id" => account.id})

      assert Repo.get_by!(Portal.Resource, id: pool.id).device_membership_criteria ==
               Portal.Resource.DeviceMembershipCriteria.devices([])
    end
  end
end
