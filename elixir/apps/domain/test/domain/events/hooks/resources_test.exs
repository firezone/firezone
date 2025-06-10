defmodule Domain.Events.Hooks.ResourcesTest do
  use ExUnit.Case, async: true
  import Domain.Events.Hooks.Resources

  setup do
    %{old_data: %{}, data: %{}}
  end

  describe "insert/1" do
    test "returns :ok" do
      resource_id = "test_resource"
      account_id = "test_account"
      :ok = subscribe(resource_id)
      :ok = Domain.Events.Hooks.Accounts.subscribe_to_resources(account_id)

      data = %{"id" => resource_id, "account_id" => account_id}

      assert :ok == on_insert(data)

      # we expect two - once for the resource subscription, and once for the account
      assert_receive {:create_resource, ^resource_id}
      assert_receive {:create_resource, ^resource_id}

      :ok = unsubscribe(resource_id)

      assert :ok = on_insert(data)
      assert_receive {:create_resource, ^resource_id}
      refute_receive {:create_resource, ^resource_id}
    end
  end

  describe "update/2" do
    test "returns :ok", %{old_data: old_data, data: data} do
      assert :ok == on_update(old_data, data)
    end
  end

  describe "delete/1" do
    test "returns :ok", %{data: data} do
      assert :ok == on_delete(data)
    end
  end
end
