defmodule Portal.Resource.DeviceMembershipCriteriaTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.SubjectFixtures

  alias Portal.Resource.DeviceMembershipCriteria

  @own_devices %{
    "device" => %{"field" => "actor_id", "op" => "eq", "value" => %{"subject" => "actor_id"}}
  }

  @device_ids Enum.sort(["7b0ac0b5-5c8e-4b6e-9a2f-4f5a7a3e0b11", "0e5c1f8a-2d3b-4c6d-8e9f-1a2b3c4d5e6f"])
  @devices %{"device" => %{"field" => "id", "op" => "in", "value" => @device_ids}}

  @all_devices %{
    "device" => %{"field" => "account_id", "op" => "eq", "value" => %{"subject" => "account_id"}}
  }

  @group_id "3f9d2c1b-8a7e-4f60-b5c4-2d1e0f9a8b7c"
  @actor_group %{"actor_group" => %{"field" => "id", "op" => "eq", "value" => @group_id}}

  describe "cast/1" do
    test "parses the own devices rule" do
      assert DeviceMembershipCriteria.cast(@own_devices) == {:ok, DeviceMembershipCriteria.own_devices()}
      assert DeviceMembershipCriteria.cast(DeviceMembershipCriteria.own_devices()) == {:ok, DeviceMembershipCriteria.own_devices()}
    end

    test "parses a device list, sorted and without duplicates" do
      assert DeviceMembershipCriteria.cast(@devices) == {:ok, DeviceMembershipCriteria.devices(@device_ids)}

      shuffled = put_in(@devices, ["device", "value"], Enum.reverse(@device_ids) ++ @device_ids)
      assert DeviceMembershipCriteria.cast(shuffled) == {:ok, DeviceMembershipCriteria.devices(@device_ids)}

      assert DeviceMembershipCriteria.cast(put_in(@devices, ["device", "value"], [])) ==
               {:ok, DeviceMembershipCriteria.devices([])}
    end

    test "parses the all devices rule" do
      assert DeviceMembershipCriteria.cast(@all_devices) == {:ok, DeviceMembershipCriteria.all_devices()}
      assert DeviceMembershipCriteria.cast(put_in(@all_devices, ["device", "value"], %{"subject" => "actor_id"})) == :error
      assert DeviceMembershipCriteria.cast(put_in(@own_devices, ["device", "value"], %{"subject" => "account_id"})) == :error
    end

    test "parses the actor group rule" do
      assert DeviceMembershipCriteria.cast(@actor_group) == {:ok, DeviceMembershipCriteria.actor_group(@group_id)}
      assert DeviceMembershipCriteria.cast(put_in(@actor_group, ["actor_group", "value"], "nope")) == :error
      assert DeviceMembershipCriteria.cast(put_in(@actor_group, ["actor_group", "value"], [@group_id])) == :error
      assert DeviceMembershipCriteria.cast(put_in(@actor_group, ["actor_group", "op"], "in")) == :error
      assert DeviceMembershipCriteria.cast(put_in(@actor_group, ["actor_group", "field"], "name")) == :error
    end

    test "rejects a device list with anything but device ids" do
      assert DeviceMembershipCriteria.cast(put_in(@devices, ["device", "value"], ["nope"])) == :error
      assert DeviceMembershipCriteria.cast(put_in(@devices, ["device", "value"], [1])) == :error
      assert DeviceMembershipCriteria.cast(put_in(@devices, ["device", "value"], %{"subject" => "actor_id"})) == :error
      assert DeviceMembershipCriteria.cast(put_in(@devices, ["device", "op"], "eq")) == :error
    end

    test "rejects anything outside the grammar" do
      assert DeviceMembershipCriteria.cast(%{}) == :error
      assert DeviceMembershipCriteria.cast(nil) == :error
      assert DeviceMembershipCriteria.cast("own_devices") == :error
      assert DeviceMembershipCriteria.cast(Map.put(@own_devices, "intune", %{})) == :error

      assert DeviceMembershipCriteria.cast(put_in(@own_devices, ["device", "field"], "hostname")) == :error
      assert DeviceMembershipCriteria.cast(put_in(@own_devices, ["device", "op"], "ne")) == :error
      assert DeviceMembershipCriteria.cast(put_in(@own_devices, ["device", "value"], "literal")) == :error

      assert DeviceMembershipCriteria.cast(put_in(@own_devices, ["device", "value"], %{"subject" => "id"})) ==
               :error

      assert DeviceMembershipCriteria.cast(put_in(@own_devices, ["device", "extra"], true)) == :error
    end
  end

  describe "dump/1 and load/1" do
    test "round-trip the rule through its wire shape" do
      assert DeviceMembershipCriteria.dump(DeviceMembershipCriteria.own_devices()) == {:ok, @own_devices}
      assert DeviceMembershipCriteria.load(@own_devices) == {:ok, DeviceMembershipCriteria.own_devices()}
      assert DeviceMembershipCriteria.to_map(DeviceMembershipCriteria.own_devices()) == @own_devices

      assert DeviceMembershipCriteria.dump(DeviceMembershipCriteria.devices(@device_ids)) == {:ok, @devices}
      assert DeviceMembershipCriteria.load(@devices) == {:ok, DeviceMembershipCriteria.devices(@device_ids)}

      assert DeviceMembershipCriteria.dump(DeviceMembershipCriteria.all_devices()) == {:ok, @all_devices}
      assert DeviceMembershipCriteria.load(@all_devices) == {:ok, DeviceMembershipCriteria.all_devices()}

      assert DeviceMembershipCriteria.dump(DeviceMembershipCriteria.actor_group(@group_id)) == {:ok, @actor_group}
      assert DeviceMembershipCriteria.load(@actor_group) == {:ok, DeviceMembershipCriteria.actor_group(@group_id)}
    end

    test "dump rejects anything but a rule" do
      assert DeviceMembershipCriteria.dump(@own_devices) == :error
    end
  end

  describe "device_ids/1" do
    test "returns the listed devices" do
      assert DeviceMembershipCriteria.device_ids(DeviceMembershipCriteria.devices(@device_ids)) ==
               {:ok, @device_ids}
    end

    test "is :error for other criteria" do
      assert DeviceMembershipCriteria.device_ids(DeviceMembershipCriteria.own_devices()) == :error
      assert DeviceMembershipCriteria.device_ids(nil) == :error
    end
  end

  describe "kind/1, group_id/1 and scope/2" do
    test "classify every rule" do
      assert DeviceMembershipCriteria.kind(DeviceMembershipCriteria.devices(@device_ids)) == :listed
      assert DeviceMembershipCriteria.kind(DeviceMembershipCriteria.own_devices()) == :own_devices
      assert DeviceMembershipCriteria.kind(DeviceMembershipCriteria.all_devices()) == :all_devices
      assert DeviceMembershipCriteria.kind(DeviceMembershipCriteria.actor_group(@group_id)) == :actor_group
    end

    test "group_id/1 returns the group of a group rule" do
      assert DeviceMembershipCriteria.group_id(DeviceMembershipCriteria.actor_group(@group_id)) == {:ok, @group_id}
      assert DeviceMembershipCriteria.group_id(DeviceMembershipCriteria.all_devices()) == :error
      assert DeviceMembershipCriteria.group_id(nil) == :error
    end

    test "only the own devices rule depends on who asks" do
      subject = subject_fixture(type: :client)

      assert DeviceMembershipCriteria.scope(DeviceMembershipCriteria.own_devices(), subject) == {:actor, subject.actor.id}
      assert DeviceMembershipCriteria.scope(DeviceMembershipCriteria.all_devices(), subject) == :all
      assert DeviceMembershipCriteria.scope(DeviceMembershipCriteria.devices([]), subject) == :all
      assert DeviceMembershipCriteria.scope(DeviceMembershipCriteria.actor_group(@group_id), subject) == :all

      assert DeviceMembershipCriteria.per_actor?(DeviceMembershipCriteria.own_devices())
      refute DeviceMembershipCriteria.per_actor?(DeviceMembershipCriteria.actor_group(@group_id))
    end
  end

  describe "member?/3" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)

      %{account: account, actor: actor, subject: subject}
    end

    test "admits the subject's own devices", %{account: account, actor: actor, subject: subject} do
      device = client_fixture(account: account, actor: actor)

      assert DeviceMembershipCriteria.member?(DeviceMembershipCriteria.own_devices(), device, subject)
    end

    test "refuses another actor's devices", %{account: account, subject: subject} do
      device = client_fixture(account: account, actor: actor_fixture(account: account))

      refute DeviceMembershipCriteria.member?(DeviceMembershipCriteria.own_devices(), device, subject)
    end

    test "admits every device in the account", %{account: account, subject: subject} do
      device = client_fixture(account: account, actor: actor_fixture(account: account))
      elsewhere = client_fixture(account: account_fixture())

      assert DeviceMembershipCriteria.member?(DeviceMembershipCriteria.all_devices(), device, subject)
      refute DeviceMembershipCriteria.member?(DeviceMembershipCriteria.all_devices(), elsewhere, subject)
    end

    test "admits the devices of the group's members", %{account: account, subject: subject} do
      group = group_fixture(account: account)
      member = actor_fixture(account: account)
      membership_fixture(account: account, actor: member, group: group)
      in_group = client_fixture(account: account, actor: member)
      outside = client_fixture(account: account, actor: actor_fixture(account: account))
      criteria = DeviceMembershipCriteria.actor_group(group.id)

      assert DeviceMembershipCriteria.member?(criteria, in_group, subject)
      refute DeviceMembershipCriteria.member?(criteria, outside, subject)
      refute DeviceMembershipCriteria.member?(DeviceMembershipCriteria.actor_group(Ecto.UUID.generate()), in_group, subject)
    end

    test "admits exactly the listed devices", %{account: account, subject: subject} do
      listed = client_fixture(account: account, actor: actor_fixture(account: account))
      other = client_fixture(account: account, actor: actor_fixture(account: account))
      criteria = DeviceMembershipCriteria.devices([listed.id])

      assert DeviceMembershipCriteria.member?(criteria, listed, subject)
      refute DeviceMembershipCriteria.member?(criteria, other, subject)
      refute DeviceMembershipCriteria.member?(DeviceMembershipCriteria.devices([]), listed, subject)
    end
  end

  describe "member?/3 with a presence snapshot" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor, type: :client)

      %{account: account, actor: actor, subject: subject}
    end

    test "answers every rule off the snapshot", %{account: account, actor: actor, subject: subject} do
      group_id = Ecto.UUID.generate()
      device_id = Ecto.UUID.generate()

      snapshot = %{id: device_id, account_id: account.id, actor_id: actor.id, group_ids: [group_id]}

      assert DeviceMembershipCriteria.member?(DeviceMembershipCriteria.all_devices(), snapshot, subject)
      assert DeviceMembershipCriteria.member?(DeviceMembershipCriteria.own_devices(), snapshot, subject)
      assert DeviceMembershipCriteria.member?(DeviceMembershipCriteria.devices([device_id]), snapshot, subject)
      assert DeviceMembershipCriteria.member?(DeviceMembershipCriteria.actor_group(group_id), snapshot, subject)
    end

    test "refuses a snapshot that matches none of the rules", %{account: account, subject: subject} do
      snapshot = %{
        id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate(),
        actor_id: Ecto.UUID.generate(),
        group_ids: [Ecto.UUID.generate()]
      }

      refute DeviceMembershipCriteria.member?(DeviceMembershipCriteria.all_devices(), snapshot, subject)
      refute DeviceMembershipCriteria.member?(DeviceMembershipCriteria.own_devices(), snapshot, subject)
      refute DeviceMembershipCriteria.member?(DeviceMembershipCriteria.devices([]), snapshot, subject)

      refute DeviceMembershipCriteria.member?(
               DeviceMembershipCriteria.actor_group(Ecto.UUID.generate()),
               %{snapshot | account_id: account.id},
               subject
             )
    end

    test "reads the groups off the snapshot and never off the database", %{account: account, subject: subject} do
      member = actor_fixture(account: account)
      group = group_fixture(account: account)
      membership_fixture(account: account, actor: member, group: group)
      device = client_fixture(account: account, actor: member)
      criteria = DeviceMembershipCriteria.actor_group(group.id)

      stale = %{id: device.id, account_id: account.id, actor_id: member.id, group_ids: []}

      refute DeviceMembershipCriteria.member?(criteria, stale, subject)

      unwritten = %{
        id: Ecto.UUID.generate(),
        account_id: account.id,
        actor_id: Ecto.UUID.generate(),
        group_ids: [group.id]
      }

      assert DeviceMembershipCriteria.member?(criteria, unwritten, subject)
    end
  end
end
