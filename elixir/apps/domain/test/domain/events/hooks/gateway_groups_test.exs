defmodule Domain.Events.Hooks.GatewayGroupsTest do
  use ExUnit.Case, async: true
  import Domain.Events.Hooks.GatewayGroups
  alias Domain.Gateways

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(%{})
    end
  end

  describe "update/2" do
    test "returns :ok for soft-deleted gateway group" do
      # Deleting a gateway group will delete the associated gateways which
      # handles all side effects we need to handle, including removing any
      # resources from the client's resource list.
      assert :ok = on_delete(%{})
    end

    test "broadcasts updated gateway group" do
      account_id = "00000000-0000-0000-0000-000000000000"

      :ok = Domain.PubSub.Account.subscribe(account_id)

      old_data = %{
        "id" => "00000000-0000-0000-0000-000000000001",
        "account_id" => account_id,
        "name" => "Old Gateway Group",
        "deleted_at" => nil
      }

      data = Map.put(old_data, "name", "Updated Gateway Group")

      assert :ok == on_update(old_data, data)

      assert_receive {:updated, %Gateways.Group{} = old_group, %Gateways.Group{} = new_group}
      assert old_group.id == old_data["id"]
      assert new_group.name == data["name"]
    end
  end

  describe "delete/1" do
    test "returns :ok" do
      # Deleting a gateway group will delete the associated gateways which
      # handles all side effects we need to handle, including removing any
      # resources from the client's resource list.
      assert :ok = on_delete(%{})
    end
  end
end
