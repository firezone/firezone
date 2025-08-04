defmodule Domain.Changes.Hooks.GatewayGroupsTest do
  use ExUnit.Case, async: true
  import Domain.Changes.Hooks.GatewayGroups
  alias Domain.{Changes.Change, Gateways, PubSub}

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "update/2" do
    test "returns :ok for soft-deleted gateway group" do
      # Deleting a gateway group will delete the associated gateways which
      # handles all side effects we need to handle, including removing any
      # resources from the client's resource list.
      assert :ok = on_delete(0, %{})
    end

    test "broadcasts updated gateway group" do
      account_id = "00000000-0000-0000-0000-000000000000"

      :ok = PubSub.Account.subscribe(account_id)

      old_data = %{
        "id" => "00000000-0000-0000-0000-000000000001",
        "account_id" => account_id,
        "name" => "Old Gateway Group",
        "deleted_at" => nil
      }

      data = Map.put(old_data, "name", "Updated Gateway Group")

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %Gateways.Group{} = old_group,
        struct: %Gateways.Group{} = new_group,
        lsn: 0
      }

      assert old_group.id == old_data["id"]
      assert new_group.name == data["name"]
    end
  end

  describe "delete/1" do
    test "returns :ok" do
      # Deleting a gateway group will delete the associated gateways which
      # handles all side effects we need to handle, including removing any
      # resources from the client's resource list.
      assert :ok = on_delete(0, %{})
    end
  end
end
