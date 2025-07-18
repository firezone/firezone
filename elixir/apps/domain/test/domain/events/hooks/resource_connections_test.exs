defmodule Domain.Events.Hooks.ResourceConnectionsTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.ResourceConnections

  describe "insert/1" do
    test "broadcasts created resource connection" do
      account = Fixtures.Accounts.create_account()
      resource = Fixtures.Resources.create_resource(account: account)
      gateway_group = Fixtures.Gateways.create_group(account: account)

      :ok = Domain.PubSub.Account.subscribe(account.id)

      data = %{
        "account_id" => account.id,
        "resource_id" => resource.id,
        "gateway_group_id" => gateway_group.id,
        "deleted_at" => nil
      }

      assert :ok == on_insert(data)

      assert_receive {:created, %Domain.Resources.Connection{} = connection}
      assert connection.account_id == data["account_id"]
      assert connection.resource_id == data["resource_id"]
      assert connection.gateway_group_id == data["gateway_group_id"]
    end
  end

  describe "update/2" do
    test "returns :ok" do
      assert :ok = on_update(%{}, %{})
    end
  end

  describe "delete/1" do
    test "broadcasts deleted connection" do
      account = Fixtures.Accounts.create_account()
      resource = Fixtures.Resources.create_resource(account: account)
      gateway_group = Fixtures.Gateways.create_group(account: account)

      :ok = Domain.PubSub.Account.subscribe(account.id)

      old_data = %{
        "account_id" => account.id,
        "resource_id" => resource.id,
        "gateway_group_id" => gateway_group.id,
        "deleted_at" => nil
      }

      assert :ok == on_delete(old_data)

      assert_receive {:deleted, %Domain.Resources.Connection{} = deleted_connection}
      assert deleted_connection.account_id == old_data["account_id"]
      assert deleted_connection.resource_id == old_data["resource_id"]
      assert deleted_connection.gateway_group_id == old_data["gateway_group_id"]
    end
  end
end
