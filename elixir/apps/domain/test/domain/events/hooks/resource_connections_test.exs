defmodule Domain.Events.Hooks.ResourceConnectionsTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.ResourceConnections

  setup do
    %{old_data: %{}, data: %{}}
  end

  describe "insert/1" do
    test "returns :ok", %{data: data} do
      assert :ok == on_insert(data)
    end
  end

  describe "update/2" do
    test "returns :ok", %{old_data: old_data, data: data} do
      assert :ok == on_update(old_data, data)
    end
  end

  describe "delete/1" do
    test "returns :ok" do
      flow = Fixtures.Flows.create_flow()
      :ok = Domain.PubSub.Flow.subscribe(flow.id)

      flow_id = flow.id
      client_id = flow.client_id
      resource_id = flow.resource_id

      assert :ok ==
               on_delete(%{"account_id" => flow.account_id, "resource_id" => flow.resource_id})

      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end
  end
end
