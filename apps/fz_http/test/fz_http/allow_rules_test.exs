defmodule FzHttp.AllowRulesTest do
  use FzHttp.DataCase, async: true

  describe "allow_rules" do
    alias EctoNetwork.INET
    alias FzHttp.{AllowRules, AllowRules.AllowRule}

    import FzHttp.{AllowRulesFixtures, GatewaysFixtures, UsersFixtures}

    test "list_allow_rules/0 returns all allow rules" do
      allow_rule = allow_rule()
      assert AllowRules.list_allow_rules() == [allow_rule]
    end

    test "list_allow_rules/1 returns allow rules scoped to a gateway" do
      _ = allow_rule(%{gateway_id: gateway().id})
      gateway = gateway(%{name: "gateway"})
      allow_rule = allow_rule(%{gateway_id: gateway.id})
      assert AllowRules.list_allow_rules(gateway) == [allow_rule]
    end

    test "list_allow_rules/1 returns allow rules scoped to a user" do
      _ = allow_rule(%{user_id: user().id})
      user = user()
      allow_rule = allow_rule(%{user_id: user.id})
      assert AllowRules.list_allow_rules(user) == [allow_rule]
    end

    test "get_allow_rule!/1 returns allow rule by its id" do
      allow_rule = allow_rule()
      assert AllowRules.get_allow_rule!(allow_rule.id) == allow_rule
    end

    test "create_allow_rule/1 with valid destination creates an allow rule" do
      valid_destination = %{
        gateway_id: gateway().id,
        destination: "10.10.10.0/24"
      }

      assert {:ok, %AllowRule{} = allow_rule} = AllowRules.create_allow_rule(valid_destination)
      assert INET.decode(allow_rule.destination) == "10.10.10.0/24"
    end

    test "create_allow_rule/1 with valid port range returns an allow rule" do
      valid_port_range = %{
        gateway_id: gateway().id,
        destination: "10.10.10.0/24",
        port_range_start: 1,
        port_range_end: 2
      }

      assert {:ok, %AllowRule{} = allow_rule} = AllowRules.create_allow_rule(valid_port_range)
      assert allow_rule.port_range_start == 1
      assert allow_rule.port_range_end == 2
    end

    test "create_allow_rule/1 with invalid gateway returns an error changeset" do
      invalid_gateway = %{
        gateway_id: nil,
        destination: "10.10.10.0/24"
      }

      assert {:error, %Ecto.Changeset{}} = AllowRules.create_allow_rule(invalid_gateway)
    end

    test "create_allow_rule/1 with invalid destination returns an error changeset" do
      invalid_destination = %{
        gateway_id: gateway().id,
        destination: nil
      }

      assert {:error, %Ecto.Changeset{}} = AllowRules.create_allow_rule(invalid_destination)
    end

    test "create_allow_rule/1 with invalid port range start returns an error changeset" do
      invalid_port_range = %{
        gateway_id: gateway().id,
        destination: "10.10.10.0/24",
        port_range_start: nil,
        port_range_end: 2
      }

      assert {:error, %Ecto.Changeset{errors: errors}} =
               AllowRules.create_allow_rule(invalid_port_range)

      assert [
               allow_rules:
                 {"A port range needs both start and end. Additionally, a protocol requires a port range.",
                  _}
             ] = errors
    end

    test "create_allow_rule/1 with invalid port range end returns an error changeset" do
      invalid_port_range = %{
        gateway_id: gateway().id,
        destination: "10.10.10.0/24",
        port_range_start: 1,
        port_range_end: 65_536
      }

      assert {:error, %Ecto.Changeset{errors: errors}} =
               AllowRules.create_allow_rule(invalid_port_range)

      [allow_rules: {"Port range start and end should be within 1 and 65,535.", _}] = errors
    end
  end
end
