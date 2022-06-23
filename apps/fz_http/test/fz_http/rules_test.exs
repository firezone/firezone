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

  describe "to_settings/0" do
    setup [:create_rules]

    test "prints all rules to nftables format", %{
      rules: expected_rules,
      users: expected_users,
      devices: expected_devices
    } do
      {users, devices, rules} = Rules.to_settings()
      expected_user_ids = MapSet.new(Enum.map(expected_users, fn user -> user.id end))

      expected_devices =
        MapSet.new(
          Enum.map(expected_devices, fn device ->
            %{
              # XXX: Ideally we could hardcode the expected ips here as not to depend on the `decode` implementation
              # However, we can't know user_id in advance, perhaps we can test the user_id part and ip parts separately
              user_id: device.user_id,
              ip: Rules.decode(device.ipv4),
              ip6: Rules.decode(device.ipv6)
            }
          end)
        )

      expected_rules =
        MapSet.new(
          Enum.map(expected_rules, fn rule ->
            %{
              user_id: rule.user_id,
              destination: Rules.decode(rule.destination),
              action: rule.action
            }
          end)
        )

      assert ^expected_user_ids = users
      assert ^expected_devices = devices
      assert ^expected_rules = rules
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

  describe "projections" do
    setup [:create_rule_with_user_and_device]

    test "returns IPv4 tuple", %{device: device, user: user, rule: rule} do
      user_id = user.id
      assert ^user_id = Rules.user_projection(user)
      assert %{destination: "10.20.30.0/24", user_id: ^user_id} = Rules.rule_projection(rule)

      assert %{user_id: ^user_id, ip: "10.3.2.2", ip6: "fd00::3:2:2"} =
               Rules.device_projection(device)
    end
  end
end
