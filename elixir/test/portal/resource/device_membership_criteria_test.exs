defmodule Portal.Resource.DeviceMembershipCriteriaTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SubjectFixtures

  alias Portal.Resource.DeviceMembershipCriteria

  @own_devices %{
    "device" => %{"field" => "actor_id", "op" => "eq", "value" => %{"subject" => "actor_id"}}
  }

  @device_ids Enum.sort(["7b0ac0b5-5c8e-4b6e-9a2f-4f5a7a3e0b11", "0e5c1f8a-2d3b-4c6d-8e9f-1a2b3c4d5e6f"])
  @devices %{"device" => %{"field" => "id", "op" => "in", "value" => @device_ids}}

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

    test "admits exactly the listed devices", %{account: account, subject: subject} do
      listed = client_fixture(account: account, actor: actor_fixture(account: account))
      other = client_fixture(account: account, actor: actor_fixture(account: account))
      criteria = DeviceMembershipCriteria.devices([listed.id])

      assert DeviceMembershipCriteria.member?(criteria, listed, subject)
      refute DeviceMembershipCriteria.member?(criteria, other, subject)
      refute DeviceMembershipCriteria.member?(DeviceMembershipCriteria.devices([]), listed, subject)
    end
  end
end
