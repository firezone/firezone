defmodule Portal.Changes.Hooks.SitesTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.Sites
  alias Portal.{Changes.Change, Site, PubSub}

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "update/2" do
    test "broadcasts updated site" do
      account_id = "00000000-0000-0000-0000-000000000000"

      :ok = PubSub.Account.subscribe(account_id)

      old_data = %{
        "id" => "00000000-0000-0000-0000-000000000001",
        "account_id" => account_id,
        "name" => "Old Site"
      }

      data = Map.put(old_data, "name", "Updated Site")

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %Site{} = old_site,
        struct: %Site{} = new_site,
        lsn: 0
      }

      assert old_site.id == old_data["id"]
      assert new_site.name == data["name"]
    end
  end

  describe "delete/1" do
    test "returns :ok" do
      # Deleting a site will delete the associated gateways which
      # handles all side effects we need to handle, including removing any
      # resources from the client's resource list.
      assert :ok = on_delete(0, %{})
    end
  end
end
