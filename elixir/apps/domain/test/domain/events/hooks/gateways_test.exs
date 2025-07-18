defmodule Domain.Events.Hooks.GatewaysTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Gateways

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(%{})
    end
  end

  describe "update/2" do
    test "soft-delete broadcasts deleted gateway" do
      account = Fixtures.Accounts.create_account()
      gateway = Fixtures.Gateways.create_gateway(account: account)

      :ok = Domain.PubSub.Account.subscribe(account.id)

      old_data = %{"id" => gateway.id, "deleted_at" => nil, "account_id" => account.id}
      data = Map.put(old_data, "deleted_at", "2023-01-01T00:00:00Z")

      assert :ok = on_update(old_data, data)

      assert_receive {:deleted, %Domain.Gateways.Gateway{} = deleted_gateway}
      assert deleted_gateway.id == gateway.id
    end

    test "soft-delete deletes flows" do
      account = Fixtures.Accounts.create_account()
      gateway = Fixtures.Gateways.create_gateway(account: account)

      old_data = %{"id" => gateway.id, "deleted_at" => nil, "account_id" => account.id}
      data = Map.put(old_data, "deleted_at", "2023-01-01T00:00:00Z")

      assert flow = Fixtures.Flows.create_flow(gateway: gateway, account: account)
      assert :ok = on_update(old_data, data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end

    test "update returns :ok" do
      assert :ok = on_update(%{}, %{})
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted gateway" do
      account = Fixtures.Accounts.create_account()
      gateway = Fixtures.Gateways.create_gateway(account: account)

      :ok = Domain.PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => gateway.id,
        "account_id" => account.id,
        "name" => "Test Gateway",
        "deleted_at" => nil
      }

      assert :ok = on_delete(old_data)

      assert_receive {:deleted, %Domain.Gateways.Gateway{} = deleted_gateway}
      assert deleted_gateway.id == gateway.id
    end

    test "deletes flows" do
      account = Fixtures.Accounts.create_account()
      gateway = Fixtures.Gateways.create_gateway(account: account)

      old_data = %{"id" => gateway.id, "account_id" => account.id, "deleted_at" => nil}

      assert flow = Fixtures.Flows.create_flow(gateway: gateway, account: account)
      assert :ok = on_delete(old_data)
      refute Repo.get_by(Domain.Flows.Flow, id: flow.id)
    end
  end
end
