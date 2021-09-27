defmodule FzHttp.DevicesTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.{Devices, Users}

  describe "list_devices/0" do
    setup [:create_device]

    test "shows all devices", %{device: device} do
      assert Devices.list_devices() == [device]
    end
  end

  describe "list_devices/1" do
    setup [:create_device]

    test "shows devices scoped to a user_id", %{device: device} do
      assert Devices.list_devices(device.user_id) == [device]
    end

    test "shows devices scoped to a user", %{device: device} do
      user = Users.get_user!(device.user_id)
      assert Devices.list_devices(user) == [device]
    end
  end

  describe "get_device!/1" do
    setup [:create_device]

    test "device is loaded", %{device: device} do
      test_device = Devices.get_device!(device.id)
      assert test_device.id == device.id
    end
  end

  describe "update_device/2" do
    setup [:create_device]

    @attrs %{
      name: "Go hard or go home.",
      allowed_ips: "0.0.0.0"
    }

    test "updates device", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @attrs)
      assert @attrs = test_device
    end
  end

  describe "delete_device/1" do
    setup [:create_device]

    test "deletes device", %{device: device} do
      {:ok, _deleted} = Devices.delete_device(device)

      assert_raise(Ecto.StaleEntryError, fn ->
        Devices.delete_device(device)
      end)

      assert_raise(Ecto.NoResultsError, fn ->
        Devices.get_device!(device.id)
      end)
    end
  end

  describe "change_device/1" do
    setup [:create_device]

    test "returns changeset", %{device: device} do
      assert %Ecto.Changeset{} = Devices.change_device(device)
    end
  end

  describe "rand_name/0" do
    test "generates a random name" do
      name1 = Devices.rand_name()
      name2 = Devices.rand_name()

      assert name1 != name2
    end
  end

  describe "to_peer_list/0" do
    setup [:create_device]

    test "renders all peers", %{device: device} do
      assert Devices.to_peer_list() |> List.first() == %{
               public_key: device.public_key,
               allowed_ips:
                 "#{Devices.ipv4_address(device)}/32, #{Devices.ipv6_address(device)}/128"
             }
    end
  end
end
