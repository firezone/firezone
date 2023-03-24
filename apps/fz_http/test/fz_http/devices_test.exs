defmodule FzHttp.DevicesTest do
  use FzHttp.DataCase, async: true
  import FzHttp.Devices
  alias FzHttp.{UsersFixtures, SubjectFixtures, DevicesFixtures}
  alias FzHttp.Devices

  setup do
    unprivileged_user = UsersFixtures.create_user_with_role(:unprivileged)
    unprivileged_subject = SubjectFixtures.create_subject(unprivileged_user)

    admin_user = UsersFixtures.create_user_with_role(:admin)
    admin_subject = SubjectFixtures.create_subject(admin_user)

    %{
      unprivileged_user: unprivileged_user,
      unprivileged_subject: unprivileged_subject,
      admin_user: admin_user,
      admin_subject: admin_subject
    }
  end

  describe "count/0" do
    test "counts devices" do
      DevicesFixtures.create_device()
      DevicesFixtures.create_device()
      DevicesFixtures.create_device()
      assert count() == 3
    end
  end

  describe "count_by_user_id/1" do
    test "returns 0 if user does not exist" do
      assert count_by_user_id(Ecto.UUID.generate()) == 0
    end

    test "returns count of devices for a user" do
      device = DevicesFixtures.create_device()
      assert count_by_user_id(device.user_id) == 1
    end
  end

  describe "count_active_within/1" do
    test "returns device count active within the last 30 seconds" do
      latest_handshake = DateTime.utc_now()

      DevicesFixtures.create_device()
      |> update_metrics(%{latest_handshake: latest_handshake})

      assert count_active_within(30) == 1
    end

    test "omits device active exceeding 30 seconds" do
      latest_handshake = DateTime.add(DateTime.utc_now(), -31)
      DevicesFixtures.create_device(latest_handshake: latest_handshake)

      assert count_active_within(30) == 0
    end
  end

  describe "fetch_device_by_id/2" do
    test "returns error when UUID is invalid", %{unprivileged_subject: subject} do
      assert fetch_device_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns device by id", %{unprivileged_user: user, unprivileged_subject: subject} do
      device = DevicesFixtures.create_device(user: user)
      assert fetch_device_by_id(device.id, subject) == {:ok, device}
    end

    test "returns device that belongs to another user with manage permission", %{
      unprivileged_subject: subject
    } do
      device = DevicesFixtures.create_device()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Devices.Authorizer.manage_devices_permission())

      assert fetch_device_by_id(device.id, subject) == {:ok, device}
    end

    test "does not return device that belongs to another user with manage_own permission", %{
      unprivileged_subject: subject
    } do
      device = DevicesFixtures.create_device()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Devices.Authorizer.manage_own_devices_permission())

      assert fetch_device_by_id(device.id, subject) == {:error, :not_found}
    end

    test "returns error when device does not exist", %{unprivileged_subject: subject} do
      assert fetch_device_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view devices", %{
      unprivileged_subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_device_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Devices.Authorizer.manage_devices_permission(),
                        Devices.Authorizer.manage_own_devices_permission()
                      ]}
                   ]
                 ]}}
    end
  end

  describe "list_devices/1" do
    test "returns empty list when there are no devices", %{admin_subject: subject} do
      assert list_devices(subject) == {:ok, []}
    end

    test "shows all devices owned by a user for unprivileged subject", %{
      unprivileged_user: user,
      admin_user: other_user,
      unprivileged_subject: subject
    } do
      device = DevicesFixtures.create_device(user: user)
      DevicesFixtures.create_device(user: other_user)

      assert list_devices(subject) == {:ok, [device]}
    end

    test "shows all devices for admin subject", %{
      unprivileged_user: other_user,
      admin_user: admin_user,
      admin_subject: subject
    } do
      DevicesFixtures.create_device(user: admin_user)
      DevicesFixtures.create_device(user: other_user)

      assert {:ok, devices} = list_devices(subject)
      assert length(devices) == 2
    end

    test "returns error when subject has no permission to manage devices", %{
      unprivileged_subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_devices(subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Devices.Authorizer.manage_devices_permission(),
                        Devices.Authorizer.manage_own_devices_permission()
                      ]}
                   ]
                 ]}}
    end
  end

  describe "new_device/0" do
    test "returns changeset with default values" do
      assert %Ecto.Changeset{data: %FzHttp.Devices.Device{}} = changeset = new_device()

      assert Map.keys(changeset.changes) == [:name, :preshared_key]
    end

    test "returns changeset with given changes" do
      attrs = %{
        "name" => "foo",
        "use_default_mtu" => false,
        "preshared_key" => "dtpJtrq8w8AA84jUKUqlFCqYcAKGPjYwy9XRFaNSH1k="
      }

      assert changeset = new_device(attrs)

      assert %Ecto.Changeset{data: %FzHttp.Devices.Device{}} = changeset

      assert changeset.changes == %{
               name: attrs["name"],
               use_default_mtu: attrs["use_default_mtu"],
               preshared_key: attrs["preshared_key"]
             }
    end
  end

  describe "change_device/1" do
    test "returns changeset with given changes", %{admin_user: user} do
      device = DevicesFixtures.create_device(user: user)

      assert changeset = change_device(device, %{"name" => "foo", "use_default_mtu" => false})
      assert %Ecto.Changeset{data: %FzHttp.Devices.Device{}} = changeset

      assert changeset.changes == %{name: "foo", use_default_mtu: false}
    end
  end

  describe "create_device_for_user/3" do
    test "returns errors on invalid attrs", %{
      admin_user: user,
      admin_subject: subject
    } do
      attrs = %{
        public_key: "x",
        preshared_key: "x",
        use_default_allowed_ips: true,
        allowed_ips: ["1.1.1.1", "11", "11", "foobar"],
        use_default_dns: true,
        dns: ["XXXX", "XXXX"],
        use_default_endpoint: true,
        endpoint: "XXX",
        use_default_persistent_keepalive: true,
        persistent_keepalive: -1,
        use_default_mtu: true,
        mtu: -1,
        ipv4: "1.1.1.1",
        ipv6: "fd01::1",
        description: String.duplicate("a", 2049)
      }

      assert {:error, changeset} = create_device_for_user(user, attrs, subject)

      assert errors_on(changeset) == %{
               allowed_ips: ["is invalid"],
               description: ["should be at most 2048 character(s)"],
               dns: ["must not be present", "should not contain duplicates"],
               endpoint: ["must not be present"],
               ipv4: ["is not in the CIDR 100.64.0.0/10"],
               ipv6: ["is not in the CIDR fd00::/106"],
               mtu: ["must not be present", "must be greater than or equal to 576"],
               persistent_keepalive: ["must not be present", "must be greater than or equal to 0"],
               preshared_key: ["should be 44 character(s)", "must be a base64-encoded string"],
               public_key: ["should be 44 character(s)", "must be a base64-encoded string"]
             }
    end

    test "allows creating device with just required attributes", %{
      admin_user: user,
      admin_subject: subject
    } do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])

      assert {:ok, device} = create_device_for_user(user, attrs, subject)

      assert device.name
      assert device.allowed_ips == []
      assert device.dns == []
      refute device.endpoint

      assert device.use_default_allowed_ips
      assert device.use_default_dns
      assert device.use_default_endpoint
      assert device.use_default_mtu
      assert device.use_default_persistent_keepalive

      assert device.public_key
      assert byte_size(device.preshared_key) == 44

      assert device.user_id == user.id

      refute is_nil(device.ipv4)
      refute is_nil(device.ipv6)
    end

    test "allows admin user to create a device for himself", %{
      admin_user: user,
      admin_subject: subject
    } do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])

      assert {:ok, _device} = create_device_for_user(user, attrs, subject)
    end

    test "allows admin user to create a device for other users", %{
      unprivileged_user: user,
      admin_subject: subject
    } do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])

      assert {:ok, _device} = create_device_for_user(user, attrs, subject)
    end

    test "allows unprivileged user to create a device for himself", %{
      unprivileged_user: user,
      admin_subject: subject
    } do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])

      assert {:ok, _device} = create_device_for_user(user, attrs, subject)
    end

    test "ignores configuration attrs when there are no configure permission", %{
      unprivileged_user: user,
      unprivileged_subject: subject
    } do
      FzHttp.Config.put_env_override(:max_devices_per_user, 100)

      fields =
        Devices.Device.__schema__(:fields) --
          [:name, :description, :preshared_key, :public_key]

      value = -1

      for field <- fields do
        %{public_key: public_key} = DevicesFixtures.device_attrs()
        attrs = Map.merge(%{public_key: public_key}, %{field => value})

        assert {:ok, device} = create_device_for_user(user, attrs, subject)
        assert Map.fetch!(device, field) != value
      end
    end

    test "does not allow unprivileged user to create a device for other users", %{
      unprivileged_subject: subject
    } do
      other_user = UsersFixtures.create_user_with_role(:unprivileged)

      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])

      assert create_device_for_user(other_user, attrs, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}
    end

    test "prevents creating more than max_devices_per_user", %{
      admin_user: user,
      admin_subject: subject
    } do
      DevicesFixtures.create_device(user: user)

      FzHttp.Config.put_env_override(:max_devices_per_user, 1)

      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])

      assert {:error, changeset} = create_device_for_user(user, attrs, subject)

      assert errors_on(changeset) == %{
               base: [
                 "Maximum device limit reached. " <>
                   "Remove an existing device before creating a new one."
               ]
             }

      assert Repo.aggregate(Devices.Device, :count) == 1
    end

    test "soft limit max network range for IPv6", %{admin_user: user, admin_subject: subject} do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])

      {:ok, cidr} = FzHttp.Types.CIDR.cast("fd00::/20")
      FzHttp.Config.put_env_override(:wireguard_ipv6_network, cidr)
      assert {:ok, device} = create_device_for_user(user, attrs, subject)
      assert %Postgrex.INET{address: {64_768, 0, 0, 0, _, _, _, _}, netmask: nil} = device.ipv6
    end

    test "returns error when device IP can't be assigned due to CIDR pool exhaustion", %{
      admin_user: user,
      admin_subject: subject
    } do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])

      {:ok, cidr} = FzHttp.Types.CIDR.cast("10.3.2.0/30")
      FzHttp.Config.put_env_override(:wireguard_ipv4_network, cidr)

      assert {:ok, _device} = create_device_for_user(user, attrs, subject)
      assert {:error, changeset} = create_device_for_user(user, attrs, subject)
      refute changeset.valid?
      assert "CIDR 10.3.2.0/30 is exhausted" in errors_on(changeset).base
    end

    test "does not allow to reuse IP addresses", %{
      admin_user: user,
      admin_subject: subject
    } do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])

      assert {:ok, device} = create_device_for_user(user, attrs, subject)

      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])
        |> Map.put(:ipv4, device.ipv4)

      assert {:error, changeset} = create_device_for_user(user, attrs, subject)
      refute changeset.valid?
      assert errors_on(changeset) == %{ipv4: ["has already been taken"]}

      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])
        |> Map.put(:ipv6, device.ipv6)

      assert {:error, changeset} = create_device_for_user(user, attrs, subject)
      refute changeset.valid?
      assert errors_on(changeset) == %{ipv6: ["has already been taken"]}
    end

    test "allows hosts for DNS and endpoint", %{admin_user: user, admin_subject: subject} do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])
        |> Map.put(:use_default_dns, false)
        |> Map.put(:dns, ["valid-dns-host.example.com"])
        |> Map.put(:use_default_endpoint, false)
        |> Map.put(:endpoint, "valid-endpoint.example.com")

      assert {:ok, _device} = create_device_for_user(user, attrs, subject)
    end

    test "allows ipv6 for DNS and endpoint", %{admin_user: user, admin_subject: subject} do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])
        |> Map.put(:use_default_dns, false)
        |> Map.put(:dns, ["fd00::1"])
        |> Map.put(:use_default_endpoint, false)
        |> Map.put(:endpoint, "[fd00::1]:8080")

      assert {:ok, _device} = create_device_for_user(user, attrs, subject)
    end

    test "returns error on duplicate DNS servers", %{admin_user: user, admin_subject: subject} do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])
        |> Map.put(:use_default_dns, false)
        |> Map.put(:dns, ["1.1.1.1", "1.1.1.1"])

      assert {:error, changeset} = create_device_for_user(user, attrs, subject)
      assert errors_on(changeset) == %{dns: ["should not contain duplicates"]}
    end

    test "returns error when use_default_* is false but corresponding fields are set", %{
      admin_user: user,
      admin_subject: subject
    } do
      attrs =
        DevicesFixtures.device_attrs()
        |> Map.take([:public_key])
        |> Map.put(:dns, ["1.1.1.1"])
        |> Map.put(:allowed_ips, ["1.1.1.1"])
        |> Map.put(:endpoint, "1.1.1.1")
        |> Map.put(:persistent_keepalive, 10)
        |> Map.put(:mtu, 1280)

      assert {:error, changeset} = create_device_for_user(user, attrs, subject)

      assert errors_on(changeset) == %{
               dns: ["must not be present"],
               allowed_ips: ["must not be present"],
               endpoint: ["must not be present"],
               mtu: ["must not be present"],
               persistent_keepalive: ["must not be present"]
             }
    end

    test "allows overriding defaults", %{
      admin_user: user,
      admin_subject: subject
    } do
      for attrs <- [
            %{
              use_default_allowed_ips: false,
              allowed_ips: [%Postgrex.INET{address: {1, 1, 1, 1}}]
            },
            %{
              use_default_dns: false,
              dns: ["1.1.1.1"]
            },
            %{
              use_default_endpoint: false,
              endpoint: "1.1.1.1"
            },
            %{
              use_default_persistent_keepalive: false,
              persistent_keepalive: 1
            },
            %{
              use_default_mtu: false,
              mtu: 1000
            }
          ] do
        attrs =
          DevicesFixtures.device_attrs()
          |> Map.take([:public_key])
          |> Map.merge(attrs)

        assert {:ok, device} = create_device_for_user(user, attrs, subject)

        for {key, value} <- attrs do
          assert Map.get(device, key) == value
        end
      end
    end

    test "returns error when subject has no permission to create devices", %{
      admin_user: user,
      admin_subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert create_device_for_user(user, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_own_devices_permission()]]}}

      unprivileged_user = UsersFixtures.create_user_with_role(:unprivileged)

      assert create_device_for_user(unprivileged_user, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}
    end
  end

  describe "update_device/3" do
    test "allows admin user to update own devices", %{admin_user: user, admin_subject: subject} do
      device = DevicesFixtures.create_device(user: user)
      attrs = %{name: "new name"}

      assert {:ok, device} = update_device(device, attrs, subject)

      assert device.name == attrs.name
    end

    test "allows admin user to update other users devices", %{
      admin_subject: subject
    } do
      device = DevicesFixtures.create_device()
      attrs = %{name: "new name"}

      assert {:ok, device} = update_device(device, attrs, subject)

      assert device.name == attrs.name
    end

    test "allows unprivileged user to update own devices", %{
      unprivileged_user: user,
      unprivileged_subject: subject
    } do
      device = DevicesFixtures.create_device(user: user)
      attrs = %{name: "new name"}

      assert {:ok, device} = update_device(device, attrs, subject)

      assert device.name == attrs.name
    end

    test "does not allow unprivileged user to update other users devices", %{
      unprivileged_subject: subject
    } do
      device = DevicesFixtures.create_device()
      attrs = %{name: "new name"}

      assert update_device(device, attrs, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}
    end

    test "does not allow to reset required fields to empty values", %{
      admin_user: user,
      admin_subject: subject
    } do
      device = DevicesFixtures.create_device(user: user)
      attrs = %{name: nil, public_key: nil}

      assert {:error, changeset} = update_device(device, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{admin_user: user, admin_subject: subject} do
      device = DevicesFixtures.create_device(user: user)

      attrs = %{
        name: String.duplicate("a", 256),
        description: String.duplicate("a", 2049)
      }

      assert {:error, changeset} = update_device(device, attrs, subject)

      assert errors_on(changeset) == %{
               description: ["should be at most 2048 character(s)"],
               name: ["should be at most 255 character(s)"]
             }
    end

    test "ignores updates for any field except name and description", %{
      admin_user: user,
      admin_subject: subject
    } do
      device = DevicesFixtures.create_device(user: user)

      fields = Devices.Device.__schema__(:fields) -- [:name, :description]
      value = -1

      for field <- fields do
        assert {:ok, updated_device} = update_device(device, %{field => value}, subject)
        assert updated_device == device
      end
    end

    test "returns error when subject has no permission to update devices", %{
      admin_user: user,
      admin_subject: subject
    } do
      device = DevicesFixtures.create_device(user: user)

      subject = SubjectFixtures.remove_permissions(subject)

      assert update_device(device, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_own_devices_permission()]]}}

      device = DevicesFixtures.create_device()

      assert update_device(device, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}
    end
  end

  describe "update_metrics/2" do
    test "ignores updates for any field except related to metrics", %{unprivileged_user: user} do
      device = DevicesFixtures.create_device(user: user)

      fields =
        Devices.Device.__schema__(:fields) --
          [:remote_ip, :latest_handshake, :rx_bytes, :tx_bytes]

      value = -1

      for field <- fields do
        assert {:ok, updated_device} = update_metrics(device, %{field => value})
        assert updated_device == device
      end
    end

    test "allows admin user to update own devices", %{unprivileged_user: user} do
      device = DevicesFixtures.create_device(user: user)

      attrs = %{
        remote_ip: "167.1.1.100",
        latest_handshake: DateTime.utc_now(),
        rx_bytes: 100,
        tx_bytes: 200
      }

      assert {:ok, device} = update_metrics(device, attrs)

      assert device.remote_ip == %Postgrex.INET{address: {167, 1, 1, 100}}
      assert device.latest_handshake == attrs.latest_handshake
      assert device.rx_bytes == attrs.rx_bytes
      assert device.tx_bytes == attrs.tx_bytes
    end
  end

  describe "delete_device/2" do
    test "raises on stale entry", %{admin_user: user, admin_subject: subject} do
      device = DevicesFixtures.create_device(user: user)

      assert {:ok, _deleted} = delete_device(device, subject)

      assert_raise(Ecto.StaleEntryError, fn ->
        delete_device(device, subject)
      end)
    end

    test "admin can delete own devices", %{admin_user: user, admin_subject: subject} do
      device = DevicesFixtures.create_device(user: user)

      assert {:ok, _deleted} = delete_device(device, subject)

      assert Repo.aggregate(Devices.Device, :count) == 0
    end

    test "admin can delete other people devices", %{
      unprivileged_user: user,
      admin_subject: subject
    } do
      device = DevicesFixtures.create_device(user: user)

      assert {:ok, _deleted} = delete_device(device, subject)

      assert Repo.aggregate(Devices.Device, :count) == 0
    end

    test "unprivileged can delete own devices", %{
      unprivileged_user: user,
      unprivileged_subject: subject
    } do
      device = DevicesFixtures.create_device(user: user)

      assert {:ok, _deleted} = delete_device(device, subject)

      assert Repo.aggregate(Devices.Device, :count) == 0
    end

    test "unprivileged can not delete other people devices", %{
      unprivileged_subject: subject
    } do
      device = DevicesFixtures.create_device()

      assert delete_device(device, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}

      assert Repo.aggregate(Devices.Device, :count) == 1
    end

    test "returns error when subject has no permission to delete devices", %{
      admin_user: user,
      admin_subject: subject
    } do
      device = DevicesFixtures.create_device(user: user)

      subject = SubjectFixtures.remove_permissions(subject)

      assert delete_device(device, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_own_devices_permission()]]}}

      device = DevicesFixtures.create_device()

      assert delete_device(device, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}
    end
  end

  describe "generate_name/1" do
    test "retains name with less than or equal to 15 chars" do
      assert generate_name("12345") == "12345"
      assert generate_name("1234567890ABCDE") == "1234567890ABCDE"
    end

    test "truncates long names that exceed 15 chars" do
      assert generate_name("1234567890ABCDEF") == "1234567890A4772"
    end
  end

  describe "setting_projection/1" do
    test "projects expected fields with device", %{unprivileged_user: user} do
      device = DevicesFixtures.create_device(user: user)

      assert setting_projection(device) == %{
               ip: to_string(device.ipv4),
               ip6: to_string(device.ipv6),
               user_id: user.id
             }
    end

    test "projects expected fields with device map", %{unprivileged_user: user} do
      device = DevicesFixtures.create_device(user: user)

      device_map =
        device
        |> Map.from_struct()
        |> Map.put(:ipv4, to_string(device.ipv4))
        |> Map.put(:ipv6, to_string(device.ipv6))

      assert setting_projection(device_map) == %{
               ip: to_string(device.ipv4),
               ip6: to_string(device.ipv6),
               user_id: user.id
             }
    end
  end

  describe "as_settings/0" do
    test "maps rules to projections" do
      devices = [
        DevicesFixtures.create_device(),
        DevicesFixtures.create_device(),
        DevicesFixtures.create_device()
      ]

      expected_devices = Enum.map(devices, &setting_projection/1) |> MapSet.new()
      assert as_settings() == expected_devices
    end
  end

  describe "to_peer_list/0" do
    test "renders peers" do
      device = DevicesFixtures.create_device()

      assert to_peer_list() == [
               %{
                 public_key: device.public_key,
                 inet: "#{device.ipv4}/32,#{device.ipv6}/128",
                 preshared_key: device.preshared_key
               }
             ]
    end

    test "does not render peers of disabled users" do
      user =
        UsersFixtures.create_user_with_role(:unprivileged)
        |> UsersFixtures.disable()

      DevicesFixtures.create_device(user: user)

      assert to_peer_list() == []
    end

    test "does not render peers for users with expired VPN session" do
      FzHttp.Config.put_system_env_override(:vpn_session_duration, 1)
      two_seconds_in_future = DateTime.utc_now() |> DateTime.add(2, :second)
      user = UsersFixtures.create_user_with_role(:unprivileged)
      DevicesFixtures.create_device(user: user)

      user = UsersFixtures.update(user, last_signed_in_at: two_seconds_in_future)
      assert to_peer_list() == []

      UsersFixtures.update(user, last_signed_in_at: nil)
      assert length(to_peer_list()) == 1
    end
  end

  describe "get_allowed_ips/2" do
    test "returns default value if use_default_allowed_ips is true" do
      device = DevicesFixtures.create_device(use_default_allowed_ips: true)
      assert get_allowed_ips(device) == defaults().default_client_allowed_ips
    end

    test "returns overridden value if use_default_allowed_ips is false" do
      device = DevicesFixtures.create_device(use_default_allowed_ips: false)
      assert get_allowed_ips(device) == device.allowed_ips
    end
  end

  describe "get_endpoint/2" do
    test "returns default value if use_default_endpoint is true" do
      device = DevicesFixtures.create_device(use_default_endpoint: true)
      assert get_endpoint(device) == defaults().default_client_endpoint
    end

    test "returns overridden value if use_default_endpoint is false" do
      device =
        DevicesFixtures.create_device(
          use_default_endpoint: false,
          endpoint: "localhost:1234"
        )

      assert get_endpoint(device) == device.endpoint
    end
  end

  describe "get_dns/2" do
    test "returns default value if use_default_dns is true" do
      device = DevicesFixtures.create_device(use_default_dns: true)
      assert get_dns(device) == defaults().default_client_dns
    end

    test "returns overridden value if use_default_dns is false" do
      device = DevicesFixtures.create_device(use_default_dns: false)
      assert get_dns(device) == device.dns
    end
  end

  describe "get_mtu/2" do
    test "returns default value if use_default_mtu is true" do
      device = DevicesFixtures.create_device(use_default_mtu: true)
      assert get_mtu(device) == defaults().default_client_mtu
    end

    test "returns overridden value if use_default_mtu is false" do
      device = DevicesFixtures.create_device(use_default_mtu: false)
      assert get_mtu(device) == device.mtu
    end
  end

  describe "get_persistent_keepalive/2" do
    test "returns default value if use_default_persistent_keepalive is true" do
      device = DevicesFixtures.create_device(use_default_persistent_keepalive: true)
      assert get_persistent_keepalive(device) == defaults().default_client_persistent_keepalive
    end

    test "returns overridden value if use_default_persistent_keepalive is false" do
      device = DevicesFixtures.create_device(use_default_persistent_keepalive: false)
      assert get_persistent_keepalive(device) == device.persistent_keepalive
    end
  end

  describe "defaults/0" do
    test "returns default settings" do
      assert defaults() == %{
               default_client_allowed_ips: [
                 %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 0},
                 %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 0}, netmask: 0}
               ],
               default_client_dns: [
                 %Postgrex.INET{address: {1, 1, 1, 1}},
                 %Postgrex.INET{address: {1, 0, 0, 1}}
               ],
               default_client_endpoint: "localhost:51820",
               default_client_mtu: 1280,
               default_client_persistent_keepalive: 25
             }
    end
  end
end
