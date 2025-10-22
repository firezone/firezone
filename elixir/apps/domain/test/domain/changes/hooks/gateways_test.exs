defmodule Domain.Changes.Hooks.GatewaysTest do
  use Domain.DataCase, async: true
  import Domain.Changes.Hooks.Gateways
  alias Domain.{Changes.Change, Gateways, PubSub}

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "update/2" do
    test "update returns :ok" do
      assert :ok = on_update(0, %{}, %{})
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted gateway" do
      account = Fixtures.Accounts.create_account()
      gateway = Fixtures.Gateways.create_gateway(account: account)

      :ok = PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => gateway.id,
        "account_id" => account.id,
        "name" => "Test Gateway"
      }

      assert :ok = on_delete(0, old_data)

      assert_receive %Change{
        op: :delete,
        old_struct: %Gateways.Gateway{} = deleted_gateway,
        lsn: 0
      }

      assert deleted_gateway.id == gateway.id
    end
  end
end
