defmodule FzHttp.DevicesTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.{Devices, Users}

  describe "list_devices/0" do
    setup [:create_device]

    test "shows all devices", %{device: device} do
      assert Devices.list_devices() == [device]
    end
  end

  describe "create_device/1" do
    setup [:create_user]

    test "creates device with empty attributes", %{user: user} do
      assert {:ok, _device} =
               Devices.create_device(%{
                 name: "dummy",
                 user_id: user.id,
                 public_key: "dummy",
                 private_key: "dummy",
                 server_public_key: "dummy"
               })
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

    @valid_dns_servers_attrs %{
      dns_servers: "1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001"
    }

    @invalid_dns_servers_attrs %{
      dns_servers: "8.8.8.8, 1.1.1, 1.0.0, 1.1.1."
    }

    @valid_allowed_ips_attrs %{
      allowed_ips: "0.0.0.0/0, ::/0, ::0/0, 192.168.1.0/24"
    }

    @invalid_allowed_ips_attrs %{
      allowed_ips: "1.1.1.1, 11, foobar"
    }

    @empty_address %{
      address: ""
    }

    @low_address %{
      address: "1"
    }

    @high_address %{
      address: "255"
    }

    test "updates device", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @attrs)
      assert @attrs = test_device
    end

    test "updates device with valid dns_servers", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @valid_dns_servers_attrs)
      assert @valid_dns_servers_attrs = test_device
    end

    test "prevents updating device with invalid dns_servers", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @invalid_dns_servers_attrs)

      assert changeset.errors[:dns_servers] == {
               "is invalid: 1.1.1 is not a valid IPv4 / IPv6 address",
               []
             }
    end

    test "prevents updating device with empty address", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @empty_address)

      assert changeset.errors[:address] == {"can't be blank", [{:validation, :required}]}
    end

    test "prevents updating device with address too low", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @low_address)

      assert changeset.errors[:address] ==
               {"must be greater than or equal to %{number}",
                [{:validation, :number}, {:kind, :greater_than_or_equal_to}, {:number, 2}]}
    end

    test "prevents updating device with address too high", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @high_address)

      assert changeset.errors[:address] ==
               {"must be less than or equal to %{number}",
                [{:validation, :number}, {:kind, :less_than_or_equal_to}, {:number, 254}]}
    end

    test "updates device with valid allowed_ips", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @valid_allowed_ips_attrs)
      assert @valid_allowed_ips_attrs = test_device
    end

    test "prevents updating device with invalid allowed_ips", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @invalid_allowed_ips_attrs)

      assert changeset.errors[:allowed_ips] == {
               "is invalid: 11 is not a valid IPv4 / IPv6 address or CIDR range",
               []
             }
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
                 "#{Devices.ipv4_address(device)}/32,#{Devices.ipv6_address(device)}/128"
             }
    end
  end
end
