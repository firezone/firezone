defmodule FgHttp.DevicesTest do
  use FgHttp.DataCase, async: true
  alias FgHttp.Devices

  describe "list_devices/0" do
    setup [:create_device]

    test "shows all devices", %{device: device} do
      assert Devices.list_devices() == [device]
    end
  end

  describe "list_devices/1" do
    setup [:create_device]

    test "shows devices scoped to a user", %{device: device} do
      assert Devices.list_devices(device.user_id) == [device]
    end

    test "rules aren't loaded", %{device: device} do
      test_device = Devices.list_devices(device.user_id) |> List.first()
      assert %Ecto.Association.NotLoaded{} = test_device.rules
    end
  end

  describe "list_devices/2" do
    setup [:create_device]

    test "rules are loaded", %{device: device} do
      test_device = Devices.list_devices(device.user_id, :with_rules) |> List.first()

      assert [] = test_device.rules
    end
  end

  describe "to_peer_list/0" do
    setup [:create_device]

    test "renders all peers", %{device: device} do
      assert Devices.to_peer_list() |> List.first() == %{
               public_key: device.public_key,
               allowed_ips: device.allowed_ips,
               preshared_key: device.preshared_key
             }
    end
  end
end
