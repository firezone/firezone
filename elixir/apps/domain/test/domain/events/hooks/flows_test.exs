defmodule Domain.Events.Hooks.FlowsTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Flows

  setup do
    %{old_data: %{}, data: %{}}
  end

  describe "insert/1" do
    test "returns :ok", %{data: data} do
      assert :ok == on_insert(data)
    end
  end

  describe "update/2" do
    test "broadcasts expire_flow if flow is expired" do
      flow_id = "flow_123"
      client_id = "client_123"
      resource_id = "resource_123"

      old_data = %{}

      data = %{
        "expires_at" => DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601(),
        "id" => flow_id,
        "client_id" => client_id,
        "resource_id" => resource_id
      }

      :ok = subscribe(flow_id)

      assert :ok == on_update(old_data, data)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "does not broadcast expire_flow if flow is not expired" do
      flow_id = "flow_123"
      client_id = "client_123"
      resource_id = "resource_123"

      old_data = %{}

      data = %{
        "expires_at" => DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601(),
        "id" => flow_id,
        "client_id" => client_id,
        "resource_id" => resource_id
      }

      :ok = subscribe(flow_id)

      assert :ok == on_update(old_data, data)
      refute_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "does not receive broadcast when not subscribed" do
      flow_id = "flow_123"
      client_id = "client_123"
      resource_id = "resource_123"

      old_data = %{}

      data = %{
        "expires_at" => DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601(),
        "id" => flow_id,
        "client_id" => client_id,
        "resource_id" => resource_id
      }

      assert :ok == on_update(old_data, data)
      refute_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "broadcasts expire_flow if flow is expired" do
      flow_id = "flow_123"
      client_id = "client_123"
      resource_id = "resource_123"

      old_data = %{}

      data = %{
        "expires_at" => DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601(),
        "id" => flow_id,
        "client_id" => client_id,
        "resource_id" => resource_id
      }

      :ok = subscribe(flow_id)

      assert :ok == on_update(old_data, data)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "does not broadcast expire_flow if flow is not expired" do
      flow_id = "flow_123"
      client_id = "client_123"
      resource_id = "resource_123"

      old_data = %{}

      data = %{
        "expires_at" => DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601(),
        "id" => flow_id,
        "client_id" => client_id,
        "resource_id" => resource_id
      }

      :ok = subscribe(flow_id)

      assert :ok == on_update(old_data, data)
      refute_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end

    test "does not receive broadcast when not subscribed" do
      flow_id = "flow_123"
      client_id = "client_123"
      resource_id = "resource_123"

      old_data = %{}

      data = %{
        "expires_at" => DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601(),
        "id" => flow_id,
        "client_id" => client_id,
        "resource_id" => resource_id
      }

      assert :ok == on_update(old_data, data)
      refute_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end
  end

  describe "delete/1" do
    test "broadcasts expire_flow" do
      flow_id = "flow_123"
      client_id = "client_123"
      resource_id = "resource_123"

      old_data = %{
        "id" => flow_id,
        "client_id" => client_id,
        "resource_id" => resource_id
      }

      :ok = subscribe(flow_id)

      assert :ok == on_delete(old_data)
      assert_receive {:expire_flow, ^flow_id, ^client_id, ^resource_id}
    end
  end
end
