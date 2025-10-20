defmodule Domain.Changes.Hooks.ResourcesTest do
  use Domain.DataCase, async: true
  import Domain.Changes.Hooks.Resources
  alias Domain.{Changes.Change, Flows, Resources, PubSub}

  describe "insert/1" do
    test "broadcasts created resource" do
      account = Fixtures.Accounts.create_account()
      filters = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]
      resource = Fixtures.Resources.create_resource(account: account, filters: filters)

      :ok = PubSub.Account.subscribe(account.id)

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
        struct: %Resources.Resource{} = created_resource,
        lsn: 0
      }

      assert created_resource.id == resource.id
      assert created_resource.account_id == resource.account_id
      assert created_resource.type == resource.type
      assert created_resource.address == resource.address
      assert created_resource.filters == resource.filters
      assert created_resource.ip_stack == resource.ip_stack
      assert created_resource.address_description == resource.address_description
    end
  end

  describe "update/2" do
    test "regular update broadcasts updated resource" do
      account = Fixtures.Accounts.create_account()
      filters = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]
      resource = Fixtures.Resources.create_resource(account: account, filters: filters)

      :ok = PubSub.Account.subscribe(account.id)

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
        old_struct: %Resources.Resource{},
        struct: %Resources.Resource{} = updated_resource,
        lsn: 0
      }

      assert updated_resource.id == resource.id
      assert updated_resource.account_id == resource.account_id
      assert updated_resource.type == resource.type
      assert updated_resource.address == "new-address.example.com"
      assert updated_resource.filters == resource.filters
      assert updated_resource.ip_stack == resource.ip_stack
      assert updated_resource.address_description == resource.address_description
    end

    test "breaking update deletes flows" do
      account = Fixtures.Accounts.create_account()
      filters = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]
      resource = Fixtures.Resources.create_resource(account: account, filters: filters)

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

      assert flow = Fixtures.Flows.create_flow(resource: resource, account: account)
      assert :ok = on_update(0, old_data, data)
      refute Repo.get_by(Flows.Flow, id: flow.id)
    end
  end

  describe "delete/1" do
    test "broadcasts deleted resource" do
      account = Fixtures.Accounts.create_account()
      filters = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]
      resource = Fixtures.Resources.create_resource(account: account, filters: filters)

      :ok = PubSub.Account.subscribe(account.id)

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
        old_struct: %Resources.Resource{} = deleted_resource,
        lsn: 0
      }

      assert deleted_resource.id == resource.id
      assert deleted_resource.account_id == resource.account_id
      assert deleted_resource.type == resource.type
      assert deleted_resource.address == resource.address
      assert deleted_resource.filters == resource.filters
      assert deleted_resource.ip_stack == resource.ip_stack
      assert deleted_resource.address_description == resource.address_description
    end

    test "deletes flows" do
      account = Fixtures.Accounts.create_account()
      filters = [%{"protocol" => "tcp", "ports" => ["80", "443"]}]
      resource = Fixtures.Resources.create_resource(account: account, filters: filters)

      old_data = %{
        "id" => resource.id,
        "account_id" => account.id,
        "address_description" => resource.address_description,
        "type" => resource.type,
        "address" => resource.address,
        "filters" => filters,
        "ip_stack" => resource.ip_stack
      }

      assert flow = Fixtures.Flows.create_flow(resource: resource, account: account)
      assert :ok = on_delete(0, old_data)
      refute Repo.get_by(Flows.Flow, id: flow.id)
    end
  end
end
