defmodule Portal.MetricsRuleTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.MetricsFixtures
  alias Portal.MetricsRule

  describe "changeset/1" do
    test "only matches on known attributes with string values" do
      assert errors_on(rule_changeset(%{match: %{"os" => "linux"}})) == %{
               match: ["may only map plan, account_id, actor_id, device_id, device_type to strings"]
             }

      refute rule_changeset(%{match: %{"plan" => 1}}).valid?
      assert rule_changeset(%{match: %{"plan" => "team", "device_type" => "client"}}).valid?
    end

    test "requires patterns and an export interval the devices accept" do
      assert errors_on(rule_changeset(%{patterns: []})) == %{patterns: ["should have at least 1 item(s)"]}

      assert errors_on(rule_changeset(%{export_interval_secs: 9})) == %{
               export_interval_secs: ["must be greater than or equal to 10"]
             }
    end
  end

  describe "list_matching/1" do
    test "returns the unexpired rules whose match the attributes contain" do
      account = team_account_fixture()
      client = client_fixture(account: account)
      attributes = MetricsRule.attributes(account, client)

      everyone = metrics_rule_fixture()
      plan = metrics_rule_fixture(match: %{"plan" => "team", "device_type" => "client"})
      actor = metrics_rule_fixture(match: %{"actor_id" => client.actor_id}, expires_at: DateTime.add(DateTime.utc_now(), 1, :day))
      metrics_rule_fixture(match: %{"plan" => "team", "device_type" => "gateway"})
      metrics_rule_fixture(match: %{"device_id" => client.id}, expires_at: DateTime.add(DateTime.utc_now(), -1, :day))

      assert attributes == %{
               "plan" => "team",
               "account_id" => account.id,
               "actor_id" => client.actor_id,
               "device_id" => client.id,
               "device_type" => "client"
             }

      assert attributes |> MetricsRule.list_matching() |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([everyone.id, plan.id, actor.id])

      assert Enum.all?([everyone, plan, actor], &MetricsRule.matches?(&1, attributes))
    end
  end

  test "labels_devices?/1 holds for rules targeting a single device or actor" do
    assert MetricsRule.labels_devices?(%MetricsRule{match: %{"device_id" => Ecto.UUID.generate()}})
    assert MetricsRule.labels_devices?(%MetricsRule{match: %{"actor_id" => Ecto.UUID.generate(), "plan" => "team"}})
    refute MetricsRule.labels_devices?(%MetricsRule{match: %{}})
    refute MetricsRule.labels_devices?(%MetricsRule{match: %{"plan" => "team", "device_type" => "client"}})
    refute MetricsRule.labels_devices?(%MetricsRule{match: %{"account_id" => Ecto.UUID.generate()}})
  end

  test "count_devices/1 counts the devices whose attributes contain the match" do
    account = team_account_fixture()
    actor = actor_fixture(account: account)
    client = client_fixture(account: account, actor: actor)
    client_fixture(account: account)
    gateway = gateway_fixture(account: account)
    client_fixture()

    assert MetricsRule.count_devices(%{"account_id" => account.id}) == 3
    assert MetricsRule.count_devices(%{"plan" => "team"}) == 3
    assert MetricsRule.count_devices(%{"plan" => "unknown"}) == 1
    assert MetricsRule.count_devices(%{"plan" => "team", "device_type" => "client"}) == 2
    assert MetricsRule.count_devices(%{"actor_id" => actor.id}) == 1
    assert MetricsRule.count_devices(%{"device_id" => client.id, "device_type" => "client"}) == 1
    assert MetricsRule.count_devices(%{"device_id" => gateway.id, "account_id" => account.id}) == 1
    assert MetricsRule.count_devices(%{"device_id" => gateway.id, "device_type" => "client"}) == 0
    assert MetricsRule.count_devices(%{}) == 4
  end

  defp rule_changeset(attrs) do
    %MetricsRule{}
    |> Ecto.Changeset.cast(Map.merge(%{patterns: ["*"]}, attrs), [:match, :patterns, :export_interval_secs])
    |> MetricsRule.changeset()
  end
end
