defmodule FzHttp.RulesTest do
  use FzHttp.DataCase, async: true
  import FzHttp.Rules
  alias FzHttp.{UsersFixtures, SubjectFixtures, RulesFixtures}
  alias FzHttp.Rules

  setup do
    FzHttp.Config.put_env_override(:wireguard_ipv4_network, %Postgrex.INET{
      address: {100, 64, 0, 0},
      netmask: 10
    })

    FzHttp.Config.put_env_override(:wireguard_ipv6_network, %Postgrex.INET{
      address: {64_768, 0, 0, 0, 0, 0, 0, 0},
      netmask: 106
    })

    user = UsersFixtures.create_user_with_role(:admin)
    subject = SubjectFixtures.create_subject(user)

    %{
      user: user,
      subject: subject
    }
  end

  describe "fetch_count_by_user_id/1" do
    test "returns 0 if user does not exist", %{subject: subject} do
      assert fetch_count_by_user_id(Ecto.UUID.generate(), subject) == {:ok, 0}
    end

    test "returns count of rules for a user", %{user: user, subject: subject} do
      rule = RulesFixtures.create_rule(user: user)
      assert fetch_count_by_user_id(rule.user_id, subject) == {:ok, 1}
    end

    test "doesn't returns rules not tied to a user", %{user: user, subject: subject} do
      RulesFixtures.create_rule()
      assert fetch_count_by_user_id(user.id, subject) == {:ok, 0}
    end
  end

  describe "fetch_rule_by_id/2" do
    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_rule_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns rule by id", %{subject: subject} do
      rule = RulesFixtures.create_rule()
      assert fetch_rule_by_id(rule.id, subject) == {:ok, rule}
    end

    test "returns error when rule does not exist", %{subject: subject} do
      assert fetch_rule_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view rules", %{
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_rule_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Rules.Authorizer.manage_rules_permission()]]}}
    end
  end

  describe "list_rules/1" do
    test "returns empty list when there are no rules", %{subject: subject} do
      assert list_rules(subject) == {:ok, []}
    end

    test "shows all rules for admin subject", %{
      user: user,
      subject: subject
    } do
      RulesFixtures.create_rule(user: user)
      RulesFixtures.create_rule()

      assert {:ok, rules} = list_rules(subject)
      assert length(rules) == 2
    end

    test "returns error when subject has no permission to manage rules", %{
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_rules(subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Rules.Authorizer.manage_rules_permission()]]}}
    end
  end

  describe "list_rules_by_user_id/2" do
    test "returns empty list when there are no user-specific rules", %{
      user: user,
      subject: subject
    } do
      RulesFixtures.create_rule()

      assert list_rules_by_user_id(user.id, subject) == {:ok, []}
    end

    test "returns empty list when user does not exist", %{
      subject: subject
    } do
      assert list_rules_by_user_id(Ecto.UUID.generate(), subject) == {:ok, []}
    end

    test "returns empty list when user ID is invalid", %{
      subject: subject
    } do
      assert list_rules_by_user_id("foo", subject) == {:ok, []}
    end

    test "shows all rules assigned to a user for admin subject", %{
      user: user,
      subject: subject
    } do
      rule = RulesFixtures.create_rule(user: user)
      RulesFixtures.create_rule()

      assert list_rules_by_user_id(user.id, subject) == {:ok, [rule]}
    end

    test "returns error when subject has no permission to manage rules", %{
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_rules_by_user_id("foo", subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Rules.Authorizer.manage_rules_permission()]]}}
    end
  end

  describe "new_rule/1" do
    test "returns changeset with default values" do
      assert %Ecto.Changeset{data: %Rules.Rule{}} = changeset = new_rule()
      assert assert changeset.changes == %{}
    end

    test "returns changeset with given changes" do
      assert changeset = new_rule(%{"port_range" => "1-100"})
      assert %Ecto.Changeset{data: %Rules.Rule{}} = changeset
      assert assert changeset.changes == %{port_range: "1 - 100"}
    end
  end

  describe "change_rule/1" do
    test "returns changeset with given changes" do
      rule = RulesFixtures.create_rule()
      assert changeset = change_rule(rule, %{"port_range" => "1-100"})
      assert %Ecto.Changeset{data: %Rules.Rule{}} = changeset
      assert assert changeset.changes == %{port_range: "1 - 100"}
    end
  end

  describe "create_rule/2" do
    test "returns changeset error on invalid attrs", %{
      subject: subject
    } do
      attrs = %{
        action: :foo,
        destination: "256.0.0.1",
        port_type: :foo,
        port_range: "foo",
        user_id: Ecto.UUID.generate()
      }

      assert {:error, changeset} = create_rule(attrs, subject)

      assert errors_on(changeset) == %{
               action: ["is invalid"],
               destination: ["is invalid"],
               port_range: ["bad format"],
               port_type: ["is invalid"]
             }
    end

    test "returns changeset error on invalid user id", %{
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs(user_id: Ecto.UUID.generate())

      assert {:error, changeset} = create_rule(attrs, subject)
      assert errors_on(changeset) == %{user: ["does not exist"]}
    end

    test "returns changeset error on invalid CIDR", %{
      subject: subject
    } do
      attrs = %{destination: "10.0 0.0/24"}

      assert {:error, changeset} = create_rule(attrs, subject)
      assert errors_on(changeset) == %{destination: ["is invalid"]}
    end

    test "returns changeset error when port_range is set without port_type", %{
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs(port_range: "10-20")

      assert {:error, changeset} = create_rule(attrs, subject)
      assert errors_on(changeset) == %{port_type: ["can't be blank"]}
    end

    test "returns changeset error when port_type is set without port_range", %{
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs(port_type: :tcp)

      assert {:error, changeset} = create_rule(attrs, subject)
      assert errors_on(changeset) == %{port_range: ["can't be blank"]}
    end

    test "returns changeset error on port range that is out of bounds", %{
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs(port_type: :tcp, port_range: "10-90000")

      assert {:error, changeset} = create_rule(attrs, subject)
      assert errors_on(changeset) == %{port_range: ["port is not within valid range"]}
    end

    test "returns changeset error on invalid port range", %{
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs(port_range: "20-10")

      assert {:error, changeset} = create_rule(attrs, subject)

      assert errors_on(changeset) == %{
               port_range: ["lower value cannot be higher than upper value"]
             }
    end

    test "returns changeset error on missing attrs", %{
      subject: subject
    } do
      attrs = %{}

      assert {:error, changeset} = create_rule(attrs, subject)
      assert errors_on(changeset) == %{destination: ["can't be blank"]}
    end

    test "returns changeset error when destination range overlaps with another rule", %{
      subject: subject
    } do
      RulesFixtures.create_rule(destination: "10.10.10.1/24")

      attrs = RulesFixtures.ipv4_rule_attrs(destination: "10.10.10.2/24")
      assert {:error, changeset} = create_rule(attrs, subject)
      assert "destination overlaps with an existing rule" in errors_on(changeset).destination

      attrs = RulesFixtures.ipv4_rule_attrs(destination: "10.10.10.100")
      assert {:error, changeset} = create_rule(attrs, subject)
      assert "destination overlaps with an existing rule" in errors_on(changeset).destination
    end

    test "rules overlap is calculated by user ids", %{
      user: user1,
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs(destination: "10.10.10.1/24")
      RulesFixtures.create_rule(destination: "10.10.10.1/24", user: user1)

      assert {:ok, _rule} = create_rule(attrs, subject)

      user2 = UsersFixtures.create_user_with_role(:admin)
      attrs = Map.merge(attrs, %{destination: "10.10.10.1/24", user_id: user2.id})
      assert {:ok, _rule} = create_rule(attrs, subject)
    end

    test "returns changeset error when port-specific destination overlap with another rule", %{
      subject: subject
    } do
      RulesFixtures.create_rule(
        destination: "10.10.10.1/24",
        port_type: :tcp,
        port_range: "10-20"
      )

      attrs =
        RulesFixtures.ipv4_rule_attrs(
          destination: "10.10.10.1/24",
          port_type: :tcp,
          port_range: "10-20"
        )

      assert {:error, changeset} = create_rule(attrs, subject)

      assert errors_on(changeset) == %{
               destination: ["destination overlaps with an existing rule"]
             }
    end

    test "rules do not overlap is calculated by port range and types", %{
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs(destination: "10.10.10.1/24")
      assert {:ok, _rule} = create_rule(attrs, subject)

      attrs = Map.merge(attrs, %{port_type: :tcp, port_range: "10-20"})
      assert {:ok, _rule} = create_rule(attrs, subject)

      attrs = Map.merge(attrs, %{port_type: :udp, port_range: "10-20"})
      assert {:ok, _rule} = create_rule(attrs, subject)

      attrs = Map.merge(attrs, %{port_type: :tcp, port_range: "21-21"})
      assert {:ok, _rule} = create_rule(attrs, subject)

      attrs = Map.merge(attrs, %{port_type: :tcp, port_range: "1-9"})
      assert {:ok, _rule} = create_rule(attrs, subject)
    end

    test "allows creating rule with just required attributes", %{
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs()

      assert {:ok, rule} = create_rule(attrs, subject)

      assert rule.action == :drop
      assert rule.destination == %Postgrex.INET{address: {10, 10, 10, 0}, netmask: 24}
      assert is_nil(rule.port_type)
      assert is_nil(rule.port_range)
      assert is_nil(rule.user_id)
    end

    test "allows creating rule for a specific user", %{
      user: user,
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs(user: user)

      assert {:ok, rule} = create_rule(attrs, subject)

      assert rule.action == :drop
      assert rule.destination == %Postgrex.INET{address: {10, 10, 10, 0}, netmask: 24}
      assert is_nil(rule.port_type)
      assert is_nil(rule.port_range)
      assert rule.user_id == user.id
    end

    test "allows creating a port-specific rule", %{
      user: user,
      subject: subject
    } do
      attrs = RulesFixtures.ipv4_rule_attrs(user: user, port_type: :tcp, port_range: "100-200")

      assert {:ok, rule} = create_rule(attrs, subject)

      assert rule.action == :drop
      assert rule.destination == %Postgrex.INET{address: {10, 10, 10, 0}, netmask: 24}
      assert rule.port_type == :tcp
      assert rule.port_range == "100 - 200"
      assert rule.user_id == user.id
    end

    test "returns error when subject has no permission to create devices", %{
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert create_rule(%{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Rules.Authorizer.manage_rules_permission()]]}}
    end
  end

  describe "update_rule/3" do
    test "allows admin user to update rules", %{user: user, subject: subject} do
      rule = RulesFixtures.create_rule(user: user)
      attrs = %{destination: "10.11.12.13/32"}

      assert {:ok, rule} = update_rule(rule, attrs, subject)

      assert rule.destination == %Postgrex.INET{address: {10, 11, 12, 13}, netmask: 32}
    end

    test "allows admin user to change user id", %{
      user: user,
      subject: subject
    } do
      rule = RulesFixtures.create_rule()
      attrs = %{user_id: user.id}

      assert {:ok, rule} = update_rule(rule, attrs, subject)

      assert rule.user_id == user.id
    end

    test "does not allow to reset required fields to empty values", %{
      user: user,
      subject: subject
    } do
      rule = RulesFixtures.create_rule(user: user)
      attrs = %{action: nil, destination: nil}

      assert {:error, changeset} = update_rule(rule, attrs, subject)

      assert errors_on(changeset) == %{
               action: ["can't be blank"],
               destination: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{user: user, subject: subject} do
      rule = RulesFixtures.create_rule(user: user)

      attrs = %{
        action: :foo,
        destination: "256.0.0.1",
        port_type: :foo,
        port_range: "foo",
        user_id: Ecto.UUID.generate()
      }

      assert {:error, changeset} = update_rule(rule, attrs, subject)

      assert errors_on(changeset) == %{
               action: ["is invalid"],
               destination: ["is invalid"],
               port_range: ["bad format"],
               port_type: ["is invalid"]
             }
    end

    test "returns error when subject has no permission to update rules", %{
      subject: subject
    } do
      rule = RulesFixtures.create_rule()

      subject = SubjectFixtures.remove_permissions(subject)

      assert update_rule(rule, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Rules.Authorizer.manage_rules_permission()]]}}
    end
  end

  describe "delete_rule/2" do
    test "raises on stale entry", %{subject: subject} do
      rule = RulesFixtures.create_rule()

      assert {:ok, _deleted} = delete_rule(rule, subject)

      assert_raise(Ecto.StaleEntryError, fn ->
        delete_rule(rule, subject)
      end)
    end

    test "allows admin to delete rules", %{subject: subject} do
      rule = RulesFixtures.create_rule()

      assert {:ok, _deleted} = delete_rule(rule, subject)

      assert Repo.aggregate(Rules.Rule, :count) == 0
    end

    test "returns error when subject has no permission to delete rules", %{
      subject: subject
    } do
      rule = RulesFixtures.create_rule()

      subject = SubjectFixtures.remove_permissions(subject)

      assert delete_rule(rule, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Rules.Authorizer.manage_rules_permission()]]}}
    end
  end

  describe "setting_projection/1" do
    test "projects expected fields with rule", %{user: user} do
      rule = RulesFixtures.create_rule(user: user)

      assert setting_projection(rule) == %{
               destination: to_string(rule.destination),
               action: rule.action,
               user_id: user.id,
               port_type: rule.port_type,
               port_range: rule.port_range
             }

      rule = RulesFixtures.create_rule()
      assert is_nil(setting_projection(rule).user_id)

      rule = RulesFixtures.create_rule(port_type: :tcp, port_range: "1 - 100")
      assert %{port_type: :tcp, port_range: "1 - 100"} = setting_projection(rule)
    end

    test "projects expected fields with rule map", %{user: user} do
      rule = RulesFixtures.create_rule(user: user)

      rule_map =
        rule
        |> Map.from_struct()
        |> Map.put(:destination, to_string(rule.destination))

      assert setting_projection(rule_map) == %{
               destination: rule_map.destination,
               action: rule_map.action,
               user_id: rule_map.user_id,
               port_type: rule_map.port_type,
               port_range: rule_map.port_range
             }
    end
  end

  describe "as_settings/0" do
    test "maps rules to projections", %{user: user} do
      devices = [
        RulesFixtures.create_rule(user: user),
        RulesFixtures.create_rule(destination: "10.10.10.1"),
        RulesFixtures.create_rule(destination: "10.10.10.2")
      ]

      expected_devices = Enum.map(devices, &setting_projection/1) |> MapSet.new()
      assert as_settings() == expected_devices
    end
  end

  describe "allowlist/0" do
    test "returns allow rules" do
      rule = RulesFixtures.create_rule(action: :accept)
      RulesFixtures.create_rule(action: :drop)

      assert Rules.allowlist() == [rule]
    end
  end

  describe "denylist/0" do
    test "returns deny rules" do
      rule = RulesFixtures.create_rule(action: :drop)
      RulesFixtures.create_rule(action: :accept)

      assert Rules.denylist() == [rule]
    end
  end
end
