defmodule Portal.Changes.Hooks.GatewaysTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Devices
  import Portal.AccountFixtures
  import Portal.GatewayFixtures
  alias Portal.Changes.Change
  alias Portal.Device
  alias Portal.PubSub

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "update/2" do
    test "update returns :ok" do
      account = account_fixture()

      assert :ok =
               on_update(
                 0,
                 %{"id" => Ecto.UUID.generate(), "type" => "gateway", "account_id" => account.id},
                 %{"id" => Ecto.UUID.generate(), "type" => "gateway", "account_id" => account.id}
               )
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted gateway" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)

      :ok = PubSub.Changes.subscribe(account.id)

      old_data = %{
        "id" => gateway.id,
        "type" => "gateway",
        "account_id" => account.id,
        "name" => "Test Gateway"
      }

      assert :ok = on_delete(0, old_data)

      assert_receive %Change{
        op: :delete,
        old_struct: %Device{} = deleted_gateway,
        lsn: 0
      }

      assert deleted_gateway.id == gateway.id
    end
  end
end
