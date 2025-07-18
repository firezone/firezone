defmodule Domain.Events.Hooks.ResourcesTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Resources
  alias Domain.PubSub

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
        "ip_stack" => resource.ip_stack,
        "deleted_at" => nil
      }

      assert :ok == on_insert(data)
      assert_receive {:created, %Domain.Resources.Resource{} = created_resource}
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
    test "soft-delete broadcasts deleted resource" do
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
        "ip_stack" => resource.ip_stack,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "deleted_at", "2023-10-01T00:00:00Z")

      assert :ok == on_update(old_data, data)

      assert_receive {:deleted, %Domain.Resources.Resource{} = deleted_resource}

      assert deleted_resource.id == resource.id
      assert deleted_resource.account_id == resource.account_id
      assert deleted_resource.type == resource.type
      assert deleted_resource.address == resource.address
      assert deleted_resource.filters == resource.filters
      assert deleted_resource.ip_stack == resource.ip_stack
      assert deleted_resource.address_description == resource.address_description
    end

    test "soft-delete deletes flows" do
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
        "ip_stack" => resource.ip_stack,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "deleted_at", "2023-10-01T00:00:00Z")

      assert flow = Fixtures.Flows.create_flow(resource: resource, account: account)
      assert :ok = on_update(old_data, data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end

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
        "ip_stack" => resource.ip_stack,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "address", "new-address.example.com")

      assert :ok == on_update(old_data, data)

      assert_receive {:updated, %Domain.Resources.Resource{},
                      %Domain.Resources.Resource{} = updated_resource}

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
        "ip_stack" => resource.ip_stack,
        "deleted_at" => nil
      }

      data = Map.put(old_data, "type", "cidr")

      assert flow = Fixtures.Flows.create_flow(resource: resource, account: account)
      assert :ok = on_update(old_data, data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
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
        "ip_stack" => resource.ip_stack,
        "deleted_at" => nil
      }

      assert :ok == on_delete(old_data)

      assert_receive {:deleted, %Domain.Resources.Resource{} = deleted_resource}

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
        "ip_stack" => resource.ip_stack,
        "deleted_at" => nil
      }

      assert flow = Fixtures.Flows.create_flow(resource: resource, account: account)
      assert :ok = on_delete(old_data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end
  end
end
