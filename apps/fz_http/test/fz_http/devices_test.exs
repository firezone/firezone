defmodule FzHttp.DevicesTest do
  # XXX: Update the device IP query to be an insert
  use FzHttp.DataCase, async: false
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
      restore_env(:wireguard_ipv4_network, "10.3.2.0/30", &on_exit/1)

      assert {:error,
              %Ecto.Changeset{
                errors: [
                  ipv4:
                    {"address pool is exhausted. Increase network size or remove some devices.",
                     []}
                ]
              }} = Devices.create_device(%{@device_attrs | user_id: user.id})
    end

    @tag ipv6_network: "fd00::3:2:0/126"
    test "sets error when ipv6 address pool is exhausted", %{user: user} do
      restore_env(:wireguard_ipv6_network, "fd00::3:2:0/126", &on_exit/1)

      assert {:error,
              %Ecto.Changeset{
                errors: [
                  ipv6:
                    {"address pool is exhausted. Increase network size or remove some devices.",
                     []}
                ]
              }} = Devices.create_device(%{@device_attrs | user_id: user.id})
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
      use_site_allowed_ips: false
    }

    @valid_dns_attrs %{
      use_site_dns: false,
      dns: "1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001"
    }

    @invalid_dns_attrs %{
      dns: "8.8.8.8, 1.1.1, 1.0.0, 1.1.1."
    }

    @duplicate_dns_attrs %{
      dns: "8.8.8.8, 1.1.1.1, 1.1.1.1, ::1, ::1, ::1, ::1, ::1, 8.8.8.8"
    }

    @valid_allowed_ips_attrs %{
      use_site_allowed_ips: false,
      allowed_ips: "0.0.0.0/0, ::/0, ::0/0, 192.168.1.0/24"
    }

    @valid_endpoint_ipv4_attrs %{
      use_site_endpoint: false,
      endpoint: "5.5.5.5"
    }

    @valid_endpoint_ipv6_attrs %{
      use_site_endpoint: false,
      endpoint: "fd00::1"
    }

    @valid_endpoint_host_attrs %{
      use_site_endpoint: false,
      endpoint: "valid-endpoint.example.com"
    }

    @invalid_endpoint_ipv4_attrs %{
      use_site_endpoint: false,
      endpoint: "265.1.1.1"
    }

    @invalid_endpoint_ipv6_attrs %{
      use_site_endpoint: false,
      endpoint: "deadbeef::1"
    }

    @invalid_endpoint_host_attrs %{
      use_site_endpoint: false,
      endpoint: "can't have this"
    }

    @empty_endpoint_attrs %{
      use_site_endpoint: false,
      endpoint: ""
    }

    @invalid_allowed_ips_attrs %{
      allowed_ips: "1.1.1.1, 11, foobar"
    }

    @fields_use_site [
      %{use_site_allowed_ips: true, allowed_ips: "1.1.1.1"},
      %{use_site_dns: true, dns: "1.1.1.1"},
      %{use_site_endpoint: true, endpoint: "1.1.1.1"},
      %{use_site_persistent_keepalive: true, persistent_keepalive: 1},
      %{use_site_mtu: true, mtu: 1000}
    ]

    test "updates device", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @attrs)
      assert @attrs = test_device
    end

    test "updates device with valid dns", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @valid_dns_attrs)
      assert @valid_dns_attrs = test_device
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

    test "prevents updating fields if use_site_", %{device: device} do
      for attrs <- @fields_use_site do
        field =
          Map.keys(attrs)
          |> Enum.filter(fn attr -> !String.starts_with?(Atom.to_string(attr), "use_site_") end)
          |> List.first()

        assert {:error, changeset} = Devices.update_device(device, attrs)

        assert changeset.errors[field] == {
                 "must not be present",
                 []
               }
      end
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

    test "prevents updating device with empty endpoint", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @empty_endpoint_attrs)

      assert changeset.errors[:endpoint] == {
               "can't be blank",
               [{:validation, :required}]
             }
    end

    test "prevents updating device with invalid dns", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @invalid_dns_attrs)

      assert changeset.errors[:dns] == {
               "is invalid: 1.1.1 is not a valid IPv4 / IPv6 address",
               []
             }
    end

    test "prevents assigning duplicate DNS servers", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @duplicate_dns_attrs)

      assert changeset.errors[:dns] == {
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

    test "prevents updating ipv4 to out of network", %{device: device} do
      {:error, changeset} = Devices.update_device(device, %{ipv4: "172.16.0.1"})

      assert changeset.errors[:ipv4] == {
               "IP must be contained within network 10.3.2.0/24",
               []
             }
    end

    test "prevents updating ipv6 to out of network", %{device: device} do
      {:error, changeset} = Devices.update_device(device, %{ipv6: "fd00::2:1:1"})

      assert changeset.errors[:ipv6] == {
               "IP must be contained within network fd00::3:2:0/120",
               []
             }
    end

    test "prevents updating ipv4 to wireguard address", %{device: device} do
      ip = Application.fetch_env!(:fz_http, :wireguard_ipv4_address)
      {:error, changeset} = Devices.update_device(device, %{ipv4: ip})

      assert changeset.errors[:ipv4] == {
               "is reserved",
               [
                 {:validation, :exclusion},
                 {:enum, [%Postgrex.INET{address: {10, 3, 2, 1}, netmask: 32}]}
               ]
             }
    end

    test "prevents updating ipv6 to wireguard address", %{device: device} do
      {:error, changeset} =
        Devices.update_device(device, %{
          ipv6: Application.fetch_env!(:fz_http, :wireguard_ipv6_address)
        })

      assert changeset.errors[:ipv6] == {
               "is reserved",
               [
                 {:validation, :exclusion},
                 {:enum, [%Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 1}, netmask: 128}]}
               ]
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
