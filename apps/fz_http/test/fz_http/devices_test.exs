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
    setup [:create_user, :create_device]

    setup context do
      if ipv4_network = context[:ipv4_network] do
        restore_env(:wireguard_ipv4_network, ipv4_network, &on_exit/1)
      else
        context
      end
    end

    setup context do
      if ipv6_network = context[:ipv6_network] do
        restore_env(:wireguard_ipv6_network, ipv6_network, &on_exit/1)
      else
        context
      end
    end

    @device_attrs %{
      name: "dummy",
      public_key: "dummy",
      private_key: "dummy",
      server_public_key: "dummy",
      user_id: nil
    }

    test "creates device with empty attributes", %{user: user} do
      assert {:ok, _device} = Devices.create_device(%{@device_attrs | user_id: user.id})
    end

    test "creates devices with default ipv4", %{device: device} do
      assert device.ipv4 == %Postgrex.INET{address: {10, 3, 2, 2}, netmask: 32}
    end

    test "creates device with default ipv6", %{device: device} do
      assert device.ipv6 == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 2}, netmask: 128}
    end

    @tag ipv4_network: "10.3.2.0/30"
    test "sets error when ipv4 address pool is exhausted", %{user: user} do
      restore_env(:wireguard_ipv4, "10.3.2.0/30", &on_exit/1)
      assert {:error, changeset} = Devices.create_device(%{@device_attrs | user_id: user.id})
    end

    @tag ipv6_network: "fd00::3:2:0/126"
    test "sets error when ipv6 address pool is exhausted", %{user: user} do
      restore_env(:wireguard_ipv6, "fd00::3:2:0/126", &on_exit/1)
      assert {:error, changeset} = Devices.create_device(%{@device_attrs | user_id: user.id})
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
      allowed_ips: "0.0.0.0",
      use_default_allowed_ips: false
    }

    @valid_dns_servers_attrs %{
      use_default_dns_servers: false,
      dns_servers: "1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001"
    }

    @invalid_dns_servers_attrs %{
      dns_servers: "8.8.8.8, 1.1.1, 1.0.0, 1.1.1."
    }

    @duplicate_dns_servers_attrs %{
      dns_servers: "8.8.8.8, 1.1.1.1, 1.1.1.1, ::1, ::1, ::1, ::1, ::1, 8.8.8.8"
    }

    @valid_allowed_ips_attrs %{
      use_default_allowed_ips: false,
      allowed_ips: "0.0.0.0/0, ::/0, ::0/0, 192.168.1.0/24"
    }

    @valid_endpoint_ipv4_attrs %{
      use_default_endpoint: false,
      endpoint: "5.5.5.5"
    }

    @valid_endpoint_ipv6_attrs %{
      use_default_endpoint: false,
      endpoint: "fd00::1"
    }

    @valid_endpoint_host_attrs %{
      use_default_endpoint: false,
      endpoint: "valid-endpoint.example.com"
    }

    @invalid_endpoint_ipv4_attrs %{
      use_default_endpoint: false,
      endpoint: "265.1.1.1"
    }

    @invalid_endpoint_ipv6_attrs %{
      use_default_endpoint: false,
      endpoint: "deadbeef::1"
    }

    @invalid_endpoint_host_attrs %{
      use_default_endpoint: false,
      endpoint: "can't have this"
    }

    @invalid_allowed_ips_attrs %{
      allowed_ips: "1.1.1.1, 11, foobar"
    }

    test "updates device", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @attrs)
      assert @attrs = test_device
    end

    test "updates device with valid dns_servers", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @valid_dns_servers_attrs)
      assert @valid_dns_servers_attrs = test_device
    end

    test "updates device with valid ipv4 endpoint", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @valid_endpoint_ipv4_attrs)
      assert @valid_endpoint_ipv4_attrs = test_device
    end

    test "updates device with valid ipv6 endpoint", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @valid_endpoint_ipv6_attrs)
      assert @valid_endpoint_ipv6_attrs = test_device
    end

    test "updates device with valid host endpoint", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @valid_endpoint_host_attrs)
      assert @valid_endpoint_host_attrs = test_device
    end

    test "prevents updating device with invalid ipv4 endpoint", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @invalid_endpoint_ipv4_attrs)

      assert changeset.errors[:endpoint] == {
               "is invalid: 265.1.1.1 is not a valid fqdn or IPv4 / IPv6 address",
               []
             }
    end

    test "prevents updating device with invalid ipv6 endpoint", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @invalid_endpoint_ipv6_attrs)

      assert changeset.errors[:endpoint] == {
               "is invalid: deadbeef::1 is not a valid fqdn or IPv4 / IPv6 address",
               []
             }
    end

    test "prevents updating device with invalid host endpoint", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @invalid_endpoint_host_attrs)

      assert changeset.errors[:endpoint] == {
               "is invalid: can't have this is not a valid fqdn or IPv4 / IPv6 address",
               []
             }
    end

    test "prevents updating device with invalid dns_servers", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @invalid_dns_servers_attrs)

      assert changeset.errors[:dns_servers] == {
               "is invalid: 1.1.1 is not a valid IPv4 / IPv6 address",
               []
             }
    end

    test "prevents assigning duplicate DNS servers", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @duplicate_dns_servers_attrs)

      assert changeset.errors[:dns_servers] == {
               "is invalid: duplicate DNS servers are not allowed: 1.1.1.1, ::1, 8.8.8.8",
               []
             }
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
               inet: "#{device.ipv4}/32,#{device.ipv6}/128"
             }
    end
  end
end
