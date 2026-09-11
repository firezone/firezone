defmodule Portal.Changes.Hooks.ResourcesTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Resources
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.ResourceFixtures
  import Portal.PolicyAuthorizationFixtures
  alias Portal.Changes.Change
  alias Portal.Resource.DeviceMembershipCriteria
  alias Portal.PolicyAuthorization
  alias Portal.Resource
  alias Portal.PubSub

  describe "insert/1" do
    test "broadcasts created resource" do
      account = account_fixture()
      filters = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]
      resource = resource_fixture(account: account, filters: filters)

      :ok = PubSub.Changes.subscribe(account.id, :resources)

      data = %{
        "id" => resource.id,
        "account_id" => account.id,
        "address_description" => resource.address_description,
        "type" => resource.type,
        "address" => resource.address,
        "filters" => filters,
        "ip_stack" => resource.ip_stack
      }

      assert :ok == on_insert(0, data)

      assert_receive %Change{
        op: :insert,
        struct: %Resource{} = created_resource,
        lsn: 0
      }

      assert created_resource.id == resource.id
      assert created_resource.account_id == resource.account_id
      assert created_resource.type == resource.type
      assert created_resource.address == resource.address
      assert created_resource.ip_stack == resource.ip_stack
      assert created_resource.address_description == resource.address_description
    end
  end

  describe "update/2" do
    test "regular update broadcasts updated resource" do
      account = account_fixture()
      filters = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]
      resource = resource_fixture(account: account, filters: filters)

      :ok = PubSub.Changes.subscribe(account.id, :resources)

      old_data = %{
        "id" => resource.id,
        "account_id" => account.id,
        "address_description" => resource.address_description,
        "type" => resource.type,
        "address" => resource.address,
        "filters" => filters,
        "ip_stack" => resource.ip_stack
      }

      data = Map.put(old_data, "address", "new-address.example.com")

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %Resource{},
        struct: %Resource{} = updated_resource,
        lsn: 0
      }

      assert updated_resource.id == resource.id
      assert updated_resource.account_id == resource.account_id
      assert updated_resource.type == resource.type
      assert updated_resource.address == "new-address.example.com"
      assert updated_resource.ip_stack == resource.ip_stack
      assert updated_resource.address_description == resource.address_description
    end

    test "breaking update deletes policy authorizations" do
      account = account_fixture()
      filters = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]
      resource = resource_fixture(account: account, filters: filters)

      old_data = %{
        "id" => resource.id,
        "account_id" => account.id,
        "address_description" => resource.address_description,
        "type" => "dns",
        "address" => resource.address,
        "filters" => filters,
        "ip_stack" => resource.ip_stack
      }

      data = Map.put(old_data, "type", "cidr")

      policy_authorization = policy_authorization_fixture(resource: resource, account: account)

      assert :ok = on_update(0, old_data, data)
      refute Repo.get_by(PolicyAuthorization, id: policy_authorization.id)
    end

    test "criteria change deletes the authorizations of devices that left the pool" do
      account = account_fixture()
      initiator = client_fixture(account: account)
      kept = client_fixture(account: account)
      dropped = client_fixture(account: account)
      pool = device_pool_resource_fixture(account: account, devices: [kept, dropped])

      kept_pa =
        policy_authorization_fixture(account: account, resource: pool, client: initiator, gateway: kept)

      dropped_pa =
        policy_authorization_fixture(account: account, resource: pool, client: initiator, gateway: dropped)

      old_data = %{
        "id" => pool.id,
        "account_id" => account.id,
        "type" => "device_pool",
        "device_membership_criteria" => DeviceMembershipCriteria.to_map(pool.device_membership_criteria)
      }

      data =
        Map.put(
          old_data,
          "device_membership_criteria",
          DeviceMembershipCriteria.to_map(DeviceMembershipCriteria.devices([kept.id]))
        )

      assert :ok = on_update(0, old_data, data)
      assert Repo.get_by(PolicyAuthorization, id: kept_pa.id)
      refute Repo.get_by(PolicyAuthorization, id: dropped_pa.id)
    end

    test "own devices criteria delete the authorizations toward other actors' devices" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      initiator = client_fixture(account: account, actor: actor)
      own = client_fixture(account: account, actor: actor)
      stranger = client_fixture(account: account)
      pool = device_pool_resource_fixture(account: account, devices: [own, stranger])

      own_pa =
        policy_authorization_fixture(account: account, resource: pool, client: initiator, gateway: own)

      stranger_pa =
        policy_authorization_fixture(account: account, resource: pool, client: initiator, gateway: stranger)

      old_data = %{
        "id" => pool.id,
        "account_id" => account.id,
        "type" => "device_pool",
        "device_membership_criteria" => DeviceMembershipCriteria.to_map(pool.device_membership_criteria)
      }

      data =
        Map.put(
          old_data,
          "device_membership_criteria",
          DeviceMembershipCriteria.to_map(DeviceMembershipCriteria.own_devices())
        )

      assert :ok = on_update(0, old_data, data)
      assert Repo.get_by(PolicyAuthorization, id: own_pa.id)
      refute Repo.get_by(PolicyAuthorization, id: stranger_pa.id)
    end
  end

  describe "delete/1" do
    test "broadcasts deleted resource" do
      account = account_fixture()
      filters = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]
      resource = resource_fixture(account: account, filters: filters)

      :ok = PubSub.Changes.subscribe(account.id, :resources)

      old_data = %{
        "id" => resource.id,
        "account_id" => account.id,
        "address_description" => resource.address_description,
        "type" => resource.type,
        "address" => resource.address,
        "filters" => filters,
        "ip_stack" => resource.ip_stack
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Change{
        op: :delete,
        old_struct: %Resource{} = deleted_resource,
        lsn: 0
      }

      assert deleted_resource.id == resource.id
      assert deleted_resource.account_id == resource.account_id
      assert deleted_resource.type == resource.type
      assert deleted_resource.address == resource.address
      assert deleted_resource.ip_stack == resource.ip_stack
      assert deleted_resource.address_description == resource.address_description
    end
  end
end
