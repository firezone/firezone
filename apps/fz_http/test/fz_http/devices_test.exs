defmodule FzHttp.DevicesTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Devices
  alias FzHttp.DevicesFixtures
  alias FzHttp.Users

  describe "count/0" do
    setup :create_devices

    test "counts devices", %{devices: devices} do
      assert length(devices) == Devices.count()
    end
  end

  describe "count/1" do
    test "returns 0" do
      assert Devices.count(nil) == 0
    end
  end

  describe "count_active_within/1" do
    @active_within 30

    test "returns device count active within the last 30 seconds" do
      DevicesFixtures.device(%{latest_handshake: DateTime.utc_now()})

      assert Devices.count_active_within(@active_within) == 1
    end

    test "omits device active exceeding 30 seconds" do
      latest_handshake = DateTime.add(DateTime.utc_now(), -31)
      DevicesFixtures.device(%{latest_handshake: latest_handshake})

      assert Devices.count_active_within(@active_within) == 0
    end
  end

  describe "list_devices/0" do
    setup [:create_device]

    test "shows all devices", %{device: device} do
      assert Devices.list_devices() == [device]
    end
  end

  describe "create_device/1" do
    setup [:create_user, :create_device]

    @device_attrs %{
      name: "dummy",
      public_key: "CHqFuS+iL3FTog5F4Ceumqlk0CU4Cl/dyUP/9F9NDnI=",
      user_id: nil,
      ipv4: "100.64.0.2",
      ipv6: "fd00::2"
    }

    test "prevents creating more than max_devices_per_user", %{device: device} do
      FzHttp.Config.put_env_override(:max_devices_per_user, 1)

      assert {:error,
              %Ecto.Changeset{
                errors: [
                  base:
                    {"Maximum device limit reached. Remove an existing device before creating a new one.",
                     []}
                ]
              }} = Devices.create_device(%{@device_attrs | user_id: device.user_id})

      assert [device] == Devices.list_devices(device.user_id)
    end

    test "creates device with empty attributes", %{user: user} do
      assert {:ok, _device} = Devices.create_device(%{@device_attrs | user_id: user.id})
    end

    test "creates devices with default ipv4", %{device: device} do
      refute is_nil(device.ipv4)
    end

    test "creates device with default ipv6", %{device: device} do
      refute is_nil(device.ipv6)
    end

    test "soft limit max network range for IPv6", %{device: device} do
      FzHttp.Config.put_env_override(:wireguard_ipv6_network, "fd00::/20")
      attrs = %{@device_attrs | ipv4: nil, ipv6: nil, user_id: device.user_id}
      assert {:ok, _device} = Devices.create_device(attrs)
    end

    test "returns error when device IP can't be assigned due to CIDR pool exhaustion", %{
      device: device
    } do
      FzHttp.Config.put_env_override(:wireguard_ipv4_network, "10.3.2.0/30")
      attrs = %{@device_attrs | ipv4: nil, ipv6: nil, user_id: device.user_id}

      assert {:ok, _device} = Devices.create_device(attrs)
      assert {:error, changeset} = Devices.create_device(attrs)
      refute changeset.valid?
      assert "CIDR 10.3.2.0/30 is exhausted" in errors_on(changeset).base
    end

    test "autogenerates preshared_key", %{user: user} do
      assert {:ok, device} = Devices.create_device(%{@device_attrs | user_id: user.id})
      assert byte_size(device.preshared_key) == 44
    end
  end

  describe "list_devices/1" do
    setup [:create_device]

    test "shows devices scoped to a user_id", %{device: device} do
      assert Devices.list_devices(device.user_id) == [device]
    end

    test "shows devices scoped to a user", %{device: device} do
      user = Users.fetch_user_by_id!(device.user_id)
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
      allowed_ips: [%Postgrex.INET{address: {0, 0, 0, 0}, netmask: nil}],
      use_default_allowed_ips: false
    }

    @valid_dns_attrs %{
      use_default_dns: false,
      dns: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
    }

    @duplicate_dns_attrs %{
      dns: ["8.8.8.8", "1.1.1.1", "1.1.1.1", "::1", "::1", "::1", "::1", "::1", "8.8.8.8"]
    }

    @valid_allowed_ips_attrs %{
      use_default_allowed_ips: false,
      allowed_ips: [
        %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 0},
        %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 0}, netmask: 0},
        %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 0}, netmask: 0},
        %Postgrex.INET{address: {192, 168, 1, 0}, netmask: 24}
      ]
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

    @empty_endpoint_attrs %{
      use_default_endpoint: false,
      endpoint: ""
    }

    @invalid_allowed_ips_attrs %{
      allowed_ips: ["1.1.1.1", "11", "foobar"]
    }

    @fields_use_default [
      %{use_default_allowed_ips: true, allowed_ips: ["1.1.1.1"]},
      %{use_default_dns: true, dns: ["1.1.1.1"]},
      %{use_default_endpoint: true, endpoint: "1.1.1.1"},
      %{use_default_persistent_keepalive: true, persistent_keepalive: 1},
      %{use_default_mtu: true, mtu: 1000}
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

    test "prevents updating fields if use_default_", %{device: device} do
      for attrs <- @fields_use_default do
        field =
          Map.keys(attrs)
          |> Enum.filter(fn attr -> !String.starts_with?(Atom.to_string(attr), "use_default_") end)
          |> List.first()

        assert {:error, changeset} = Devices.update_device(device, attrs)

        assert changeset.errors[field] == {
                 "must not be present",
                 []
               }
      end
    end

    @tag attrs: %{use_default_dns: false, dns: ["foobar.com"]}
    test "allows hosts for DNS", %{attrs: attrs, device: device} do
      assert {:ok, _device} = Devices.update_device(device, attrs)
    end

    test "prevents updating device with empty endpoint", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @empty_endpoint_attrs)

      assert changeset.errors[:endpoint] == {
               "can't be blank",
               [{:validation, :required}]
             }
    end

    test "prevents assigning duplicate DNS servers", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @duplicate_dns_attrs)
      assert changeset.errors[:dns] == {"should not contain duplicates", []}
    end

    test "updates device with valid allowed_ips", %{device: device} do
      {:ok, test_device} = Devices.update_device(device, @valid_allowed_ips_attrs)
      assert @valid_allowed_ips_attrs = test_device
    end

    test "prevents updating device with invalid allowed_ips", %{device: device} do
      {:error, changeset} = Devices.update_device(device, @invalid_allowed_ips_attrs)

      assert changeset.errors[:allowed_ips] ==
               {"is invalid", [{:type, {:array, FzHttp.Types.INET}}, {:validation, :cast}]}
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

  describe "to_peer_list/0" do
    setup [:create_device]

    test "renders all peers", %{device: device} do
      assert Devices.to_peer_list() |> List.first() |> Map.delete(:preshared_key) == %{
               public_key: device.public_key,
               inet: "#{device.ipv4}/32,#{device.ipv6}/128"
             }
    end
  end

  describe "Device.new_name/0,1" do
    test "retains name with less than or equal to 15 chars" do
      assert Devices.new_name("12345") == "12345"
      assert Devices.new_name("1234567890ABCDE") == "1234567890ABCDE"
    end

    test "truncates long names that exceed 15 chars" do
      assert Devices.new_name("1234567890ABCDEF") == "1234567890A4772"
    end
  end

  describe "setting_projection/1" do
    setup [:create_rule_with_user_and_device]

    test "projects expected fields with device", %{device: device, user: user} do
      user_id = user.id

      assert %{ip: _, ip6: _, user_id: ^user_id} = Devices.setting_projection(device)
    end

    test "projects expected fields with device map", %{device: device, user: user} do
      user_id = user.id

      device_map =
        device
        |> Map.from_struct()
        |> Map.put(:ipv4, FzHttp.Devices.decode(device.ipv4))
        |> Map.put(:ipv6, FzHttp.Devices.decode(device.ipv6))

      assert %{ip: _, ip6: _, user_id: ^user_id} = Devices.setting_projection(device_map)
    end
  end

  describe "as_settings/0" do
    setup [:create_rules]

    test "Maps rules to projections", %{devices: devices} do
      expected_devices = Enum.map(devices, &Devices.setting_projection/1) |> MapSet.new()

      assert Devices.as_settings() == expected_devices
    end
  end
end
