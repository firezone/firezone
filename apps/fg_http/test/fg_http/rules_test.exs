defmodule FgHttp.RulesTest do
  use FgHttp.DataCase, async: true

  alias FgHttp.{Repo, Rules}

  describe "get_rule!/1" do
    setup [:create_rule]

    test "fetches Rule when id exists", %{rule: rule} do
      assert rule == Rules.get_rule!(rule.id)
    end

    test "raises error when id does not exist", %{rule: _rule} do
      assert_raise(Ecto.NoResultsError, fn ->
        Rules.get_rule!(0)
      end)
    end
  end

  describe "new_rule/1" do
    test "returns changeset" do
      assert %Ecto.Changeset{} = Rules.new_rule()
    end
  end

  describe "create_rule/1" do
    setup [:create_device]

    test "creates rule", %{device: device} do
      {:ok, rule} = Rules.create_rule(%{destination: "::1", device_id: device.id})
      assert !is_nil(rule.id)
      assert rule.action == :deny
    end
  end

  describe "delete_rule/1" do
    setup [:create_rule]

    test "deletes rule", %{rule: rule} do
      Rules.delete_rule(rule)

      assert_raise(Ecto.NoResultsError, fn ->
        Rules.get_rule!(rule.id)
      end)
    end
  end

  describe "to_iptables/0" do
    setup [:create_rules]

    @iptables_rules [
      {"10.0.0.1", "::1", "1.1.1.0/24", :deny},
      {"10.0.0.1", "::1", "2.2.2.0/24", :deny},
      {"10.0.0.1", "::1", "3.3.3.0/24", :deny},
      {"10.0.0.1", "::1", "4.4.4.0/24", :deny},
      {"10.0.0.1", "::1", "5.5.5.0/24", :deny}
    ]

    test "prints all rules to iptables format", %{rules: _rules} do
      assert @iptables_rules == Rules.to_iptables()
    end
  end

  describe "allowlist/1" do
    setup [:create_allow_rule]

    test "returns allow rules for a device", %{rule: rule} do
      test_rule = Repo.preload(rule, :device)
      assert Rules.allowlist(test_rule.device) == [rule]
    end

    test "returns allow rules for a device_id", %{rule: rule} do
      assert Rules.allowlist(rule.device_id) == [rule]
    end
  end

  describe "denylist/1" do
    setup [:create_deny_rule]

    test "returns deny rules for a device", %{rule: rule} do
      test_rule = Repo.preload(rule, :device)
      assert Rules.denylist(test_rule.device) == [rule]
    end

    test "returns deny rules for a device_id", %{rule: rule} do
      assert Rules.denylist(rule.device_id) == [rule]
    end
  end

  describe "iptables_spec/1 IPv4" do
    setup [:create_rule4]

    @ipv4tables_spec {"10.0.0.1", "10.10.10.0/24", :deny}

    test "returns IPv4 tuple", %{rule4: rule} do
      assert @ipv4tables_spec = Rules.iptables_spec(rule)
    end
  end

  describe "iptables_spec/1 IPv6" do
    setup [:create_rule6]

    @ipv6tables_spec {"::1", "::/0", :deny}

    test "returns IPv6 tuple", %{rule6: rule} do
      assert @ipv6tables_spec = Rules.iptables_spec(rule)
    end
  end
end
