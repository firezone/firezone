defmodule Portal.Changes.Hooks.MetricsRulesTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.MetricsRules
  alias Portal.{Changes.Change, MetricsRule, PubSub}

  @data %{
    "id" => "00000000-0000-0000-0000-000000000000",
    "match" => %{"account_id" => "00000000-0000-0000-0000-000000000001"},
    "patterns" => ["a"]
  }

  setup do
    :ok = PubSub.Changes.subscribe_to_metrics_rules()
  end

  test "on_insert/2 broadcasts the new rule" do
    assert :ok == on_insert(0, @data)

    assert_receive %Change{
      op: :insert,
      lsn: 0,
      struct: %MetricsRule{match: %{"account_id" => "00000000-0000-0000-0000-000000000001"}, patterns: ["a"]}
    }
  end

  test "on_update/3 broadcasts the old and the updated rule" do
    assert :ok == on_update(0, @data, %{@data | "match" => %{}})

    assert_receive %Change{
      op: :update,
      old_struct: %MetricsRule{match: %{"account_id" => _account_id}},
      struct: %MetricsRule{match: %{}}
    }
  end

  test "on_delete/2 broadcasts the deleted rule" do
    assert :ok == on_delete(0, @data)

    assert_receive %Change{op: :delete, old_struct: %MetricsRule{patterns: ["a"]}}
  end
end
