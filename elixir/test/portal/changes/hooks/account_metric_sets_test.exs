defmodule Portal.Changes.Hooks.AccountMetricSetsTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.AccountMetricSets
  alias Portal.{AccountMetricSet, Changes.Change, PubSub}

  @account_id "00000000-0000-0000-0000-000000000000"

  @data %{
    "id" => "00000000-0000-0000-0000-000000000001",
    "account_id" => @account_id,
    "patterns" => ["a"]
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :account_metric_sets)
  end

  test "on_insert/2 broadcasts the new set" do
    assert :ok == on_insert(0, @data)

    assert_receive %Change{op: :insert, lsn: 0, struct: %AccountMetricSet{patterns: ["a"]}}
  end

  test "on_update/3 broadcasts the updated set" do
    assert :ok == on_update(0, @data, %{@data | "patterns" => ["b"]})

    assert_receive %Change{
      op: :update,
      old_struct: %AccountMetricSet{patterns: ["a"]},
      struct: %AccountMetricSet{patterns: ["b"]}
    }
  end

  test "on_delete/2 broadcasts the deleted set" do
    assert :ok == on_delete(0, @data)

    assert_receive %Change{op: :delete, old_struct: %AccountMetricSet{account_id: @account_id}}
  end
end
