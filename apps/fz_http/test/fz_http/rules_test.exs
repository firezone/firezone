defmodule FzHttp.RulesTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Rules

  setup do
    FzHttp.Config.put_env_override(:wireguard_ipv4_network, "100.64.0.0/10")
    FzHttp.Config.put_env_override(:wireguard_ipv6_network, "fd00::0/106")

    :ok
  end

  describe "list_rules/0" do
    setup [:create_rules]

    test "lists all Rules", %{rules: rules} do
      assert length(rules) == length(Rules.list_rules())
    end
  end

  describe "list_rules/1" do
    setup [:create_rule_with_user_and_device]

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
        Rules.get_rule!(Ecto.UUID.generate())
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

    test "creates rule with port" do
      {:ok, rule} =
        Rules.create_rule(%{destination: "10.0.0.0/24", port_type: :tcp, port_range: "100-200"})

      assert !is_nil(rule.id)
      assert rule.action == :drop
      assert rule.user_id == nil
      assert rule.port_type == :tcp
      assert rule.port_range == "100 - 200"
    end

    test "prevents invalid CIDRs" do
      {:error, changeset} = Rules.create_rule(%{destination: "10.0 0.0/24"})

      assert changeset.errors[:destination] ==
               {"is invalid", [type: FzHttp.Types.INET, validation: :cast]}
    end

    test "prevents invalid port_range: no port_type" do
      {:error, changeset} = Rules.create_rule(%{destination: "10.0.0.0/24", port_range: "10-20"})

      assert changeset.errors[:port_type] ==
               {"port_type must be specified with port_range",
                [constraint: :check, constraint_name: "port_range_needs_type"]}
    end

    test "prevents invalid port_type: no port_range" do
      {:error, changeset} = Rules.create_rule(%{destination: "10.0.0.0/24", port_type: :tcp})

      assert changeset.errors[:port_type] ==
               {"port_type must be specified with port_range",
                [constraint: :check, constraint_name: "port_range_needs_type"]}
    end

    test "prevents invalid port_range: outside port range" do
      {:error, changeset} =
        Rules.create_rule(%{destination: "10.0.0.0/24", port_type: :tcp, port_range: "10-90000"})

      assert changeset.errors[:port_range] ==
               {"port is not within valid range",
                [constraint: :check, constraint_name: "port_range_is_within_valid_values"]}
    end

    test "prevents invalid port_range: " do
      {:error, changeset} =
        Rules.create_rule(%{destination: "10.0.0.0/24", port_type: :tcp, port_range: "20-10"})

      assert changeset.errors[:port_range] ==
               {"lower value cannot be higher than upper value",
                [type: FzHttp.Int4Range, validation: :cast]}
    end
  end

  describe "update_rule/2" do
    setup [:create_rule]

    @tag params: %{
           "destination" => "123.123.123.123",
           "action" => "accept",
           "port_type" => "udp",
           "port_range" => [1, 65_000]
         }
    test "updates rule with string params", %{rule: rule, params: params} do
      assert {:ok, rule} = Rules.update_rule(rule, params)
      assert rule.destination == %Postgrex.INET{address: {123, 123, 123, 123}}
      assert rule.action == :accept
      assert rule.port_type == :udp
      assert rule.port_range == "1 - 65000"
    end

    @tag attrs: %{
           destination: "123.123.123.123",
           action: "accept",
           port_type: "udp",
           port_range: [1, 65_000]
         }
    test "updates rule with atom attrs", %{rule: rule, attrs: attrs} do
      assert {:ok, rule} = Rules.update_rule(rule, attrs)
      assert rule.destination == %Postgrex.INET{address: {123, 123, 123, 123}}
      assert rule.action == :accept
      assert rule.port_type == :udp
      assert rule.port_range == "1 - 65000"
    end

    # XXX: Do we want to allow changing a rule's user_id?
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

  describe "setting_projection/1" do
    setup [:create_rule_with_user_and_device]

    test "projects expected fields with rule", %{rule: rule, user: user} do
      user_id = user.id
      assert %{destination: "10.20.30.0/24", user_id: ^user_id} = Rules.setting_projection(rule)
    end

    test "projects expected fields with rule map", %{rule: rule, user: user} do
      user_id = user.id

      rule_map =
        rule
        |> Map.from_struct()
        |> Map.put(:destination, FzHttp.Devices.decode(rule.destination))

      assert %{destination: "10.20.30.0/24", user_id: ^user_id} =
               Rules.setting_projection(rule_map)
    end
  end

  describe "setting_projection/1 with ports" do
    setup [:create_rule_with_ports]

    test "projects expected fields", %{rule: rule} do
      assert %{
               destination: "10.10.10.0/24",
               port_type: :udp,
               port_range: "10 - 20",
               action: :drop,
               user_id: nil
             } = Rules.setting_projection(rule)
    end
  end

  describe "as_settings/0" do
    setup [:create_rules]

    test "maps rules to projections", %{rules: rules} do
      expected_rules = Enum.map(rules, &Rules.setting_projection/1) |> MapSet.new()

      assert Rules.as_settings() == expected_rules
    end
  end
end
