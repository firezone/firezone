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

  describe "cast/1" do
    test "parses the own devices rule" do
      assert DeviceMembershipCriteria.cast(@own_devices) == {:ok, DeviceMembershipCriteria.own_devices()}
      assert DeviceMembershipCriteria.cast(DeviceMembershipCriteria.own_devices()) == {:ok, DeviceMembershipCriteria.own_devices()}
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
    end

    test "dump rejects anything but a rule" do
      assert DeviceMembershipCriteria.dump(@own_devices) == :error
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
  end
end
