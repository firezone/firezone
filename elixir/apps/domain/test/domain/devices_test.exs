defmodule Domain.DevicesTest do
  use Domain.DataCase, async: true
  import Domain.Devices
  alias Domain.Devices

  setup do
    account = Fixtures.Accounts.create_account()

    unprivileged_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)

    unprivileged_identity =
      Fixtures.Auth.create_identity(account: account, actor: unprivileged_actor)

    unprivileged_subject = Fixtures.Auth.create_subject(unprivileged_identity)

    admin_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    admin_identity = Fixtures.Auth.create_identity(account: account, actor: admin_actor)
    admin_subject = Fixtures.Auth.create_subject(admin_identity)

    %{
      account: account,
      unprivileged_actor: unprivileged_actor,
      unprivileged_identity: unprivileged_identity,
      unprivileged_subject: unprivileged_subject,
      admin_actor: admin_actor,
      admin_identity: admin_identity,
      admin_subject: admin_subject
    }
  end

  describe "count_by_account_id/0" do
    test "counts devices for an account", %{account: account} do
      Fixtures.Devices.create_device(account: account)
      Fixtures.Devices.create_device(account: account)
      Fixtures.Devices.create_device(account: account)
      Fixtures.Devices.create_device()

      assert count_by_account_id(account.id) == 3
    end
  end

  describe "count_by_actor_id/1" do
    test "returns 0 if actor does not exist" do
      assert count_by_actor_id(Ecto.UUID.generate()) == 0
    end

    test "returns count of devices for a actor" do
      device = Fixtures.Devices.create_device()
      assert count_by_actor_id(device.actor_id) == 1
    end
  end

  describe "fetch_device_by_id/2" do
    test "returns error when UUID is invalid", %{unprivileged_subject: subject} do
      assert fetch_device_by_id("foo", subject) == {:error, :not_found}
    end

    test "does not return deleted devices", %{
      unprivileged_actor: actor,
      unprivileged_subject: subject
    } do
      device =
        Fixtures.Devices.create_device(actor: actor)
        |> Fixtures.Devices.delete_device()

      assert fetch_device_by_id(device.id, subject) == {:error, :not_found}
    end

    test "returns device by id", %{unprivileged_actor: actor, unprivileged_subject: subject} do
      device = Fixtures.Devices.create_device(actor: actor)
      assert fetch_device_by_id(device.id, subject) == {:ok, device}
    end

    test "returns device that belongs to another actor with manage permission", %{
      account: account,
      unprivileged_subject: subject
    } do
      device = Fixtures.Devices.create_device(account: account)

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.add_permission(Devices.Authorizer.manage_devices_permission())

      assert fetch_device_by_id(device.id, subject) == {:ok, device}
    end

    test "does not returns device that belongs to another account with manage permission", %{
      unprivileged_subject: subject
    } do
      device = Fixtures.Devices.create_device()

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.add_permission(Devices.Authorizer.manage_devices_permission())

      assert fetch_device_by_id(device.id, subject) == {:error, :not_found}
    end

    test "does not return device that belongs to another actor with manage_own permission", %{
      unprivileged_subject: subject
    } do
      device = Fixtures.Devices.create_device()

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.add_permission(Devices.Authorizer.manage_own_devices_permission())

      assert fetch_device_by_id(device.id, subject) == {:error, :not_found}
    end

    test "returns error when device does not exist", %{unprivileged_subject: subject} do
      assert fetch_device_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view devices", %{
      unprivileged_subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

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

    test "does not list deleted devices", %{
      unprivileged_actor: actor,
      unprivileged_subject: subject
    } do
      Fixtures.Devices.create_device(actor: actor)
      |> Fixtures.Devices.delete_device()

      assert list_devices(subject) == {:ok, []}
    end

    test "does not list  devices in other accounts", %{
      unprivileged_subject: subject
    } do
      Fixtures.Devices.create_device()

      assert list_devices(subject) == {:ok, []}
    end

    test "shows all devices owned by a actor for unprivileged subject", %{
      unprivileged_actor: actor,
      admin_actor: other_actor,
      unprivileged_subject: subject
    } do
      device = Fixtures.Devices.create_device(actor: actor)
      Fixtures.Devices.create_device(actor: other_actor)

      assert list_devices(subject) == {:ok, [device]}
    end

    test "shows all devices for admin subject", %{
      unprivileged_actor: other_actor,
      admin_actor: admin_actor,
      admin_subject: subject
    } do
      Fixtures.Devices.create_device(actor: admin_actor)
      Fixtures.Devices.create_device(actor: other_actor)

      assert {:ok, devices} = list_devices(subject)
      assert length(devices) == 2
    end

    test "returns error when subject has no permission to manage devices", %{
      unprivileged_subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

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

  describe "list_devices_by_actor_id/2" do
    test "returns empty list when there are no devices for a given actor", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      assert list_devices_by_actor_id(Ecto.UUID.generate(), subject) == {:ok, []}
      assert list_devices_by_actor_id(actor.id, subject) == {:ok, []}
      Fixtures.Devices.create_device()
      assert list_devices_by_actor_id(actor.id, subject) == {:ok, []}
    end

    test "returns error when actor id is invalid", %{admin_subject: subject} do
      assert list_devices_by_actor_id("foo", subject) == {:error, :not_found}
    end

    test "does not list deleted devices", %{
      unprivileged_actor: actor,
      unprivileged_identity: identity,
      unprivileged_subject: subject
    } do
      Fixtures.Devices.create_device(identity: identity)
      |> Fixtures.Devices.delete_device()

      assert list_devices_by_actor_id(actor.id, subject) == {:ok, []}
    end

    test "does not deleted devices for actors in other accounts", %{
      unprivileged_subject: unprivileged_subject,
      admin_subject: admin_subject
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user)
      Fixtures.Devices.create_device(actor: actor)

      assert list_devices_by_actor_id(actor.id, unprivileged_subject) == {:ok, []}
      assert list_devices_by_actor_id(actor.id, admin_subject) == {:ok, []}
    end

    test "shows only devices owned by a actor for unprivileged subject", %{
      unprivileged_actor: actor,
      admin_actor: other_actor,
      unprivileged_subject: subject
    } do
      device = Fixtures.Devices.create_device(actor: actor)
      Fixtures.Devices.create_device(actor: other_actor)

      assert list_devices_by_actor_id(actor.id, subject) == {:ok, [device]}
      assert list_devices_by_actor_id(other_actor.id, subject) == {:ok, []}
    end

    test "shows all devices owned by another actor for admin subject", %{
      unprivileged_actor: other_actor,
      admin_actor: admin_actor,
      admin_subject: subject
    } do
      Fixtures.Devices.create_device(actor: admin_actor)
      Fixtures.Devices.create_device(actor: other_actor)

      assert {:ok, [_device]} = list_devices_by_actor_id(admin_actor.id, subject)
      assert {:ok, [_device]} = list_devices_by_actor_id(other_actor.id, subject)
    end

    test "returns error when subject has no permission to manage devices", %{
      unprivileged_subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_devices_by_actor_id(Ecto.UUID.generate(), subject) ==
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

  describe "change_device/1" do
    test "returns changeset with given changes", %{admin_actor: actor} do
      device = Fixtures.Devices.create_device(actor: actor)
      device_attrs = Fixtures.Devices.device_attrs()

      assert changeset = change_device(device, device_attrs)
      assert %Ecto.Changeset{data: %Domain.Devices.Device{}} = changeset

      assert changeset.changes == %{name: device_attrs.name}
    end
  end

  describe "upsert_device/2" do
    test "returns errors on invalid attrs", %{
      admin_subject: subject
    } do
      attrs = %{
        external_id: nil,
        public_key: "x",
        ipv4: "1.1.1.256",
        ipv6: "fd01::10000"
      }

      assert {:error, changeset} = upsert_device(attrs, subject)

      assert errors_on(changeset) == %{
               public_key: ["should be 44 character(s)", "must be a base64-encoded string"],
               external_id: ["can't be blank"]
             }
    end

    test "allows creating device with just required attributes", %{
      admin_actor: actor,
      admin_identity: identity,
      admin_subject: subject
    } do
      attrs =
        Fixtures.Devices.device_attrs()
        |> Map.delete(:name)

      assert {:ok, device} = upsert_device(attrs, subject)

      assert device.name

      assert device.public_key == attrs.public_key

      assert device.actor_id == actor.id
      assert device.identity_id == identity.id
      assert device.account_id == actor.account_id

      refute is_nil(device.ipv4)
      refute is_nil(device.ipv6)

      assert device.last_seen_remote_ip == %Postgrex.INET{address: subject.context.remote_ip}
      assert device.last_seen_user_agent == subject.context.user_agent
      assert device.last_seen_version == "0.7.412"
      assert device.last_seen_at
    end

    test "updates device when it already exists", %{
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device(subject: subject)
      attrs = Fixtures.Devices.device_attrs(external_id: device.external_id)

      subject = %{
        subject
        | context: %Domain.Auth.Context{
            subject.context
            | remote_ip: {100, 64, 100, 101},
              user_agent: "iOS/12.5 (iPhone) connlib/0.7.411"
          }
      }

      assert {:ok, updated_device} = upsert_device(attrs, subject)

      assert Repo.aggregate(Devices.Device, :count, :id) == 1

      assert updated_device.name
      assert updated_device.last_seen_remote_ip.address == subject.context.remote_ip
      assert updated_device.last_seen_remote_ip != device.last_seen_remote_ip
      assert updated_device.last_seen_user_agent == subject.context.user_agent
      assert updated_device.last_seen_user_agent != device.last_seen_user_agent
      assert updated_device.last_seen_version == "0.7.411"
      assert updated_device.public_key != device.public_key
      assert updated_device.public_key == attrs.public_key

      assert updated_device.actor_id == device.actor_id
      assert updated_device.identity_id == device.identity_id
      assert updated_device.ipv4 == device.ipv4
      assert updated_device.ipv6 == device.ipv6
      assert updated_device.last_seen_at
      assert updated_device.last_seen_at != device.last_seen_at
    end

    test "does not reserve additional addresses on update", %{
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device(subject: subject)

      attrs =
        Fixtures.Devices.device_attrs(
          external_id: device.external_id,
          last_seen_user_agent: "iOS/12.5 (iPhone) connlib/0.7.411",
          last_seen_remote_ip: %Postgrex.INET{address: {100, 64, 100, 100}}
        )

      assert {:ok, updated_device} = upsert_device(attrs, subject)

      addresses =
        Domain.Network.Address
        |> Repo.all()
        |> Enum.map(fn %Domain.Network.Address{address: address, type: type} ->
          %{address: address, type: type}
        end)

      assert length(addresses) == 2
      assert %{address: updated_device.ipv4, type: :ipv4} in addresses
      assert %{address: updated_device.ipv6, type: :ipv6} in addresses
    end

    test "allows unprivileged actor to create a device for himself", %{
      admin_subject: subject
    } do
      attrs =
        Fixtures.Devices.device_attrs()
        |> Map.delete(:name)

      assert {:ok, _device} = upsert_device(attrs, subject)
    end

    test "does not allow to reuse IP addresses", %{
      account: account,
      admin_subject: subject
    } do
      attrs = Fixtures.Devices.device_attrs(account: account)
      assert {:ok, device} = upsert_device(attrs, subject)

      addresses =
        Domain.Network.Address
        |> Repo.all()
        |> Enum.map(fn %Domain.Network.Address{address: address, type: type} ->
          %{address: address, type: type}
        end)

      assert length(addresses) == 2
      assert %{address: device.ipv4, type: :ipv4} in addresses
      assert %{address: device.ipv6, type: :ipv6} in addresses

      assert_raise Ecto.ConstraintError, fn ->
        Fixtures.Network.create_address(address: device.ipv4, account: account)
      end

      assert_raise Ecto.ConstraintError, fn ->
        Fixtures.Network.create_address(address: device.ipv6, account: account)
      end
    end

    test "ip addresses are unique per account", %{
      account: account,
      admin_subject: subject
    } do
      attrs = Fixtures.Devices.device_attrs(account: account)
      assert {:ok, device} = upsert_device(attrs, subject)

      assert %Domain.Network.Address{} = Fixtures.Network.create_address(address: device.ipv4)
      assert %Domain.Network.Address{} = Fixtures.Network.create_address(address: device.ipv6)
    end

    test "returns error when subject has no permission to create devices", %{
      admin_subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert upsert_device(%{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_own_devices_permission()]]}}
    end
  end

  describe "update_device/3" do
    test "allows admin actor to update own devices", %{admin_actor: actor, admin_subject: subject} do
      device = Fixtures.Devices.create_device(actor: actor)
      attrs = %{name: "new name"}

      assert {:ok, device} = update_device(device, attrs, subject)

      assert device.name == attrs.name
    end

    test "allows admin actor to update other actors devices", %{
      account: account,
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device(account: account)
      attrs = %{name: "new name"}

      assert {:ok, device} = update_device(device, attrs, subject)

      assert device.name == attrs.name
    end

    test "allows unprivileged actor to update own devices", %{
      unprivileged_actor: actor,
      unprivileged_subject: subject
    } do
      device = Fixtures.Devices.create_device(actor: actor)
      attrs = %{name: "new name"}

      assert {:ok, device} = update_device(device, attrs, subject)

      assert device.name == attrs.name
    end

    test "does not allow unprivileged actor to update other actors devices", %{
      account: account,
      unprivileged_subject: subject
    } do
      device = Fixtures.Devices.create_device(account: account)
      attrs = %{name: "new name"}

      assert update_device(device, attrs, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}
    end

    test "does not allow admin actor to update devices in other accounts", %{
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device()
      attrs = %{name: "new name"}

      assert update_device(device, attrs, subject) == {:error, :not_found}
    end

    test "does not allow to reset required fields to empty values", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device(actor: actor)
      attrs = %{name: nil, public_key: nil}

      assert {:error, changeset} = update_device(device, attrs, subject)

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{admin_actor: actor, admin_subject: subject} do
      device = Fixtures.Devices.create_device(actor: actor)

      attrs = %{
        name: String.duplicate("a", 256)
      }

      assert {:error, changeset} = update_device(device, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"]
             }
    end

    test "ignores updates for any field except name", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device(actor: actor)

      fields = Devices.Device.__schema__(:fields) -- [:name]
      value = -1

      for field <- fields do
        assert {:ok, updated_device} = update_device(device, %{field => value}, subject)
        assert updated_device == device
      end
    end

    test "returns error when subject has no permission to update devices", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device(actor: actor)

      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_device(device, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_own_devices_permission()]]}}

      device = Fixtures.Devices.create_device()

      assert update_device(device, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}
    end
  end

  describe "delete_device/2" do
    test "returns error on state conflict", %{admin_actor: actor, admin_subject: subject} do
      device = Fixtures.Devices.create_device(actor: actor)

      assert {:ok, deleted} = delete_device(device, subject)
      assert delete_device(deleted, subject) == {:error, :not_found}
      assert delete_device(device, subject) == {:error, :not_found}
    end

    test "admin can delete own devices", %{admin_actor: actor, admin_subject: subject} do
      device = Fixtures.Devices.create_device(actor: actor)

      assert {:ok, deleted} = delete_device(device, subject)
      assert deleted.deleted_at
    end

    test "admin can delete other people devices", %{
      unprivileged_actor: actor,
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device(actor: actor)

      assert {:ok, deleted} = delete_device(device, subject)
      assert deleted.deleted_at
    end

    test "admin can not delete devices in other accounts", %{
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device()

      assert delete_device(device, subject) == {:error, :not_found}
    end

    test "unprivileged can delete own devices", %{
      account: account,
      unprivileged_actor: actor,
      unprivileged_subject: subject
    } do
      device = Fixtures.Devices.create_device(account: account, actor: actor)

      assert {:ok, deleted} = delete_device(device, subject)
      assert deleted.deleted_at
    end

    test "unprivileged can not delete other people devices", %{
      account: account,
      unprivileged_subject: subject
    } do
      device = Fixtures.Devices.create_device()

      assert delete_device(device, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}

      device = Fixtures.Devices.create_device(account: account)

      assert delete_device(device, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}

      assert Repo.aggregate(Devices.Device, :count) == 2
    end

    test "returns error when subject has no permission to delete devices", %{
      admin_actor: actor,
      admin_subject: subject
    } do
      device = Fixtures.Devices.create_device(actor: actor)

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_device(device, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_own_devices_permission()]]}}

      device = Fixtures.Devices.create_device()

      assert delete_device(device, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Devices.Authorizer.manage_devices_permission()]]}}
    end
  end

  describe "delete_actor_devices/1" do
    test "removes all devices that belong to an actor" do
      actor = Fixtures.Actors.create_actor()
      Fixtures.Devices.create_device(actor: actor)
      Fixtures.Devices.create_device(actor: actor)
      Fixtures.Devices.create_device(actor: actor)

      assert Repo.aggregate(Devices.Device.Query.all(), :count) == 3
      assert delete_actor_devices(actor) == :ok
      assert Repo.aggregate(Devices.Device.Query.all(), :count) == 0
    end

    test "does not remove devices that belong to another actor" do
      actor = Fixtures.Actors.create_actor()
      Fixtures.Devices.create_device()

      assert delete_actor_devices(actor) == :ok
      assert Repo.aggregate(Devices.Device.Query.all(), :count) == 1
    end
  end
end
