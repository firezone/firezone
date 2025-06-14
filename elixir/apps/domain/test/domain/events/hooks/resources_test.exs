defmodule Domain.Events.Hooks.ResourcesTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Resources
  alias Domain.PubSub

  describe "insert/1" do
    test "broadcasts :create_resource to subscribed" do
      resource_id = "test_resource"
      account_id = "test_account"
      :ok = PubSub.Resource.subscribe(resource_id)
      :ok = PubSub.Account.Resources.subscribe(account_id)

      data = %{"id" => resource_id, "account_id" => account_id}

      assert :ok == on_insert(data)

      # we expect two - once for the resource subscription, and once for the account
      assert_receive {:create_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}

      :ok = PubSub.Resource.unsubscribe(resource_id)

      assert :ok = on_insert(data)
      assert_receive {:create_resource, ^resource_id}
      refute_receive {:create_resource, ^resource_id}
    end
  end

  describe "update/2" do
    setup do
      flow = Fixtures.Flows.create_flow()

      old_data = %{
        "type" => "dns",
        "address" => "1.2.3.4",
        "filters" => [],
        "ip_stack" => "dual",
        "id" => flow.resource_id,
        "account_id" => flow.account_id
      }

      %{flow: flow, old_data: old_data}
    end

    test "broadcasts :delete_resource to subscribed for soft-deletions" do
      resource_id = "test_resource"
      account_id = "test_account"
      :ok = PubSub.Resource.subscribe(resource_id)
      :ok = PubSub.Account.Resources.subscribe(account_id)

      old_data = %{"id" => resource_id, "account_id" => account_id, "deleted_at" => nil}

      data = %{
        "id" => resource_id,
        "account_id" => account_id,
        "deleted_at" => DateTime.utc_now()
      }

      assert :ok == on_update(old_data, data)
      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:delete_resource, ^resource_id}

      :ok = PubSub.Resource.unsubscribe(resource_id)

      assert :ok = on_update(old_data, data)
      assert_receive {:delete_resource, ^resource_id}
      refute_receive {:delete_resource, ^resource_id}
    end

    test "expires flows when resource type changes", %{flow: flow, old_data: old_data} do
      :ok = PubSub.Resource.subscribe(flow.resource_id)
      :ok = PubSub.Account.Resources.subscribe(flow.account_id)

      data = Map.put(old_data, "type", "cidr")

      assert :ok == on_update(old_data, data)

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)
      flow = Repo.reload(flow)

      assert DateTime.compare(DateTime.utc_now(), flow.expires_at) == :gt

      resource_id = flow.resource_id

      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}
    end

    test "expires flows when resource address changes", %{flow: flow, old_data: old_data} do
      :ok = PubSub.Resource.subscribe(flow.resource_id)
      :ok = PubSub.Account.Resources.subscribe(flow.account_id)

      data = Map.put(old_data, "address", "4.3.2.1")

      assert :ok == on_update(old_data, data)

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)
      flow = Repo.reload(flow)

      assert DateTime.compare(DateTime.utc_now(), flow.expires_at) == :gt

      resource_id = flow.resource_id

      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}
    end

    test "expires flows when resource filters change", %{flow: flow, old_data: old_data} do
      :ok = PubSub.Resource.subscribe(flow.resource_id)
      :ok = PubSub.Account.Resources.subscribe(flow.account_id)

      data = Map.put(old_data, "filters", ["new_filter"])

      assert :ok == on_update(old_data, data)

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)
      flow = Repo.reload(flow)

      assert DateTime.compare(DateTime.utc_now(), flow.expires_at) == :gt

      resource_id = flow.resource_id

      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}
    end

    test "expires flows when resource ip_stack changes", %{flow: flow, old_data: old_data} do
      :ok = PubSub.Resource.subscribe(flow.resource_id)
      :ok = PubSub.Account.Resources.subscribe(flow.account_id)

      data = Map.put(old_data, "ip_stack", "ipv4_only")

      assert :ok == on_update(old_data, data)

      # TODO: WAL
      # Remove this after direct broadcast
      Process.sleep(100)
      flow = Repo.reload(flow)

      assert DateTime.compare(DateTime.utc_now(), flow.expires_at) == :gt

      resource_id = flow.resource_id

      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}
    end

    test "broadcasts update for non-addressability change", %{flow: flow, old_data: old_data} do
      :ok = PubSub.Resource.subscribe(flow.resource_id)
      :ok = PubSub.Account.Resources.subscribe(flow.account_id)

      data = Map.put(old_data, "name", "New Name")

      assert :ok == on_update(old_data, data)

      assert DateTime.compare(DateTime.utc_now(), flow.expires_at) == :lt

      resource_id = flow.resource_id

      assert_receive {:update_resource, ^resource_id}
      assert_receive {:update_resource, ^resource_id}
      refute_receive {:delete_resource, ^resource_id}
      refute_receive {:create_resource, ^resource_id}
    end
  end

  describe "delete/1" do
    test "broadcasts :delete_resource to subscribed" do
      resource_id = "test_resource"
      account_id = "test_account"
      :ok = PubSub.Resource.subscribe(resource_id)
      :ok = PubSub.Account.Resources.subscribe(account_id)

      old_data = %{"id" => resource_id, "account_id" => account_id}

      assert :ok == on_delete(old_data)
      assert_receive {:delete_resource, ^resource_id}
      assert_receive {:delete_resource, ^resource_id}

      :ok = PubSub.Resource.unsubscribe(resource_id)

      assert :ok = on_delete(old_data)
      assert_receive {:delete_resource, ^resource_id}
      refute_receive {:delete_resource, ^resource_id}
    end
  end
end
