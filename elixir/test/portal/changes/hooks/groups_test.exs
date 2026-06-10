defmodule Portal.Changes.Hooks.GroupsTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Groups
  import Portal.AccountFixtures
  import Portal.GroupFixtures
  alias Portal.Changes.Change
  alias Portal.Group
  alias Portal.PubSub

  describe "on_insert/2" do
    test "broadcasts created group" do
      account = account_fixture()
      group = group_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id)

      data = %{
        "id" => group.id,
        "account_id" => account.id,
        "name" => group.name,
        "type" => group.type
      }

      assert :ok == on_insert(0, data)

      assert_receive %Change{op: :insert, struct: %Group{} = created_group, lsn: 0}

      assert created_group.id == group.id
      assert created_group.account_id == group.account_id
      assert created_group.name == group.name
      assert created_group.type == group.type
    end
  end

  describe "on_delete/2" do
    test "broadcasts deleted group" do
      account = account_fixture()
      group = group_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id)

      old_data = %{
        "id" => group.id,
        "account_id" => account.id,
        "name" => group.name,
        "type" => group.type
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Change{op: :delete, old_struct: %Group{} = deleted_group, lsn: 0}

      assert deleted_group.id == group.id
      assert deleted_group.account_id == group.account_id
      assert deleted_group.name == group.name
      assert deleted_group.type == group.type
    end
  end
end
