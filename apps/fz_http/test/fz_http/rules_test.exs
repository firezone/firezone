defmodule FzHttp.RulesTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Rules

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
      {"5.5.5.0/24", :drop}
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

  # XXX: Revisit this when devices are linked to rules
  # describe "nftables_spec/1 IPv4" do
  #   setup [:create_rule4]
  #
  #   @ipv4tables_spec {"10.0.0.1", "10.10.10.0/24", :drop}
  #
  #   test "returns IPv4 tuple", %{rule4: rule} do
  #     assert @ipv4tables_spec = Rules.nftables_spec(rule)
  #   end
  # end
  #
  # describe "nftables_spec/1 IPv6" do
  #   setup [:create_rule6]
  #
  #   @ipv6tables_spec {"::1", "::/0", :drop}
  #
  #   test "returns IPv6 tuple", %{rule6: rule} do
  #     assert @ipv6tables_spec = Rules.nftables_spec(rule)
  #   end
  # end
end
