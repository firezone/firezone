defmodule Domain.Changes.Hooks.ResourceConnectionsTest do
  use Domain.DataCase, async: true
  import Domain.Changes.Hooks.ResourceConnections
  alias Domain.{Changes.Change, Resources, PubSub}

  describe "insert/1" do
    test "broadcasts created resource connection" do
      account = Fixtures.Accounts.create_account()
      resource = Fixtures.Resources.create_resource(account: account)
      site = Fixtures.Sites.create_site(account: account)

      :ok = PubSub.Account.subscribe(account.id)

      data = %{
        "account_id" => account.id,
        "resource_id" => resource.id,
        "site_id" => site.id
      }

      assert :ok == on_insert(0, data)

      assert_receive %Change{
        op: :insert,
        struct: %Resources.Connection{} = connection,
        lsn: 0
      }

      assert connection.account_id == data["account_id"]
      assert connection.resource_id == data["resource_id"]
      assert connection.site_id == data["site_id"]
    end
  end

  describe "update/2" do
    test "returns :ok" do
      assert :ok = on_update(0, %{}, %{})
    end
  end

  describe "delete/1" do
    test "broadcasts deleted connection" do
      account = Fixtures.Accounts.create_account()
      resource = Fixtures.Resources.create_resource(account: account)
      site = Fixtures.Sites.create_site(account: account)

      :ok = PubSub.Account.subscribe(account.id)

      old_data = %{
        "account_id" => account.id,
        "resource_id" => resource.id,
        "site_id" => site.id
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Change{
        op: :delete,
        old_struct: %Resources.Connection{} = deleted_connection,
        lsn: 0
      }

      assert deleted_connection.account_id == old_data["account_id"]
      assert deleted_connection.resource_id == old_data["resource_id"]
      assert deleted_connection.site_id == old_data["site_id"]
    end
  end
end
