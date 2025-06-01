defmodule Domain.Events.Hooks.GatewaysTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Gateways

  setup do
    %{old_data: %{}, data: %{}}
  end

  describe "insert/1" do
    test "returns :ok", %{data: data} do
      assert :ok == on_insert(data)
    end
  end

  describe "update/2" do
    test "soft-delete broadcasts disconnect" do
      gateway = Fixtures.Gateways.create_gateway()

      old_data = %{"id" => gateway.id, "deleted_at" => nil}
      data = %{"id" => gateway.id, "deleted_at" => "2023-10-01T00:00:00Z"}

      :ok = connect(gateway)
      :ok = on_update(old_data, data)

      assert_receive "disconnect"
    end

    test "regular update does not broadcast disconnect" do
      gateway = Fixtures.Gateways.create_gateway()

      old_data = %{"id" => gateway.id}
      data = %{"id" => gateway.id, "name" => "New Gateway Name"}

      :ok = connect(gateway)
      :ok = on_update(old_data, data)

      refute_receive "disconnect"
    end
  end

  describe "delete/1" do
    test "delete broadcasts disconnect" do
      gateway = Fixtures.Gateways.create_gateway()

      old_data = %{"id" => gateway.id}

      :ok = connect(gateway)
      :ok = on_delete(old_data)

      assert_receive "disconnect"
    end
  end
end
