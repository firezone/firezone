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

      assert DateTime.compare(DateTime.utc_now(), flow.expires_at) == :lt

      assert :ok == on_delete(%{"resource_id" => flow.resource_id})

      # TODO: WAL
      # Remove this when flow removal is directly broadcasted
      Process.sleep(100)

      flow = Repo.reload(flow)

      assert DateTime.compare(DateTime.utc_now(), flow.expires_at) == :gt
    end
  end
end
