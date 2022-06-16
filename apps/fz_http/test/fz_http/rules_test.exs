defmodule FzHttp.RulesTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Rules

  describe "list_rules/0" do
    setup [:create_rules]

    test "lists all Rules", %{rules: rules} do
      assert length(rules) == length(Rules.list_rules())
    end
  end

  describe "list_rules/1" do
    setup [:create_rule_with_user]

    test "list Rules scoped by user", %{user: user, rule: rule} do
      assert Rules.list_rules(user.id) == [rule]
    end

    test "Deleting user deletes rule", %{user: user, rule: rule} do
      assert rule in Rules.list_rules()
      FzHttp.Users.delete_user(user)
      assert rule not in Rules.list_rules()
    end
  end

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
    test "creates rule" do
      {:ok, rule} = Rules.create_rule(%{destination: "::1"})
      assert !is_nil(rule.id)
      assert rule.action == :drop
      assert rule.user_id == nil
    end

    test "prevents invalid CIDRs" do
      {:error, changeset} = Rules.create_rule(%{destination: "10.0 0.0/24"})

      assert changeset.errors[:destination] ==
               {"is invalid", [type: EctoNetwork.INET, validation: :cast]}
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

  describe "to_nftables/0" do
    setup [:create_rules]

    @nftables_rules [
      {"1.1.1.0/24", :drop},
      {"2.2.2.0/24", :drop},
      {"3.3.3.0/24", :drop},
      {"4.4.4.0/24", :drop},
      {"5.5.5.0/24", :drop},
      {"10.3.2.4", "4.4.4.0/24", :drop},
      {"10.3.2.5", "5.5.5.0/24", :drop},
      {"10.3.2.6", "6.6.6.0/24", :drop}
    ]

    test "prints all rules to nftables format", %{rules: _rules} do
      assert @nftables_rules == Rules.to_nftables()
    end
  end

  describe "allowlist/0" do
    setup [:create_accept_rule]

    test "returns allow rules", %{rule: rule} do
      assert Rules.allowlist() == [rule]
    end
  end

  describe "denylist/0" do
    setup [:create_drop_rule]

    test "returns deny rules", %{rule: rule} do
      assert Rules.denylist() == [rule]
    end
  end

  describe "nftables_spec/1 IPv4" do
    setup [:create_rule4]

    @ipv4tables_spec [{"10.10.10.0/24", :drop}]

    test "returns IPv4 tuple", %{rule4: rule} do
      assert @ipv4tables_spec = Rules.nftables_spec(rule)
    end
  end

  describe "nftables_spec/1 with user IPv4" do
    setup [:create_rule4_with_user]

    @ipv4tables_spec [
      {"10.3.2.2", "10.10.10.0/24", :drop},
      {"10.3.2.3", "10.10.10.0/24", :drop},
      {"10.3.2.4", "10.10.10.0/24", :drop},
      {"10.3.2.5", "10.10.10.0/24", :drop}
    ]

    test "returns IPv4 tuple", %{rule4: rule} do
      assert @ipv4tables_spec = Rules.nftables_spec(rule)
    end
  end

  describe "nftables_spec/1 with user IPv6" do
    setup [:create_rule6_with_user]

    @ipv6tables_spec [
      {"fd00::3:2:2", "::/0", :drop},
      {"fd00::3:2:3", "::/0", :drop},
      {"fd00::3:2:4", "::/0", :drop},
      {"fd00::3:2:5", "::/0", :drop}
    ]

    test "returns IPv6 tuple", %{rule6: rule} do
      assert @ipv6tables_spec = Rules.nftables_spec(rule)
    end
  end

  describe "nftables_spec/1 with user no devices" do
    setup [:create_rule_with_user]

    @iptables_spec []

    test "returns Empty", %{rule: rule} do
      assert @iptables_spec = Rules.nftables_spec(rule)
    end
  end

  describe "nftables_device_spec/1" do
    setup [:create_device_with_rules]

    @ipv4tables_spec [
      {"10.3.2.2", "1.1.1.0/24", :drop},
      {"10.3.2.2", "2.2.2.0/24", :drop},
      {"10.3.2.2", "3.3.3.0/24", :drop},
      {"10.3.2.2", "4.4.4.0/24", :drop},
      {"fd00::3:2:2", "1::/112", :drop},
      {"fd00::3:2:2", "2::/112", :drop},
      {"fd00::3:2:2", "3::/112", :drop},
      {"fd00::3:2:2", "4::/112", :drop}
    ]

    test "returns IPv4 tuple", %{device: device} do
      assert @ipv4tables_spec = Rules.nftables_device_spec(device)
    end
  end
end
