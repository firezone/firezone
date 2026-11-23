defmodule Portal.Changes.Hooks.AccountMetricsTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.AccountMetrics
  alias Portal.{AccountMetrics, Changes.Change, PubSub}

  @account_id "00000000-0000-0000-0000-000000000000"

  @data %{
    "account_id" => @account_id,
    "patterns" => ["a"]
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :account_metrics)
  end

  test "on_insert/2 broadcasts the new patterns" do
    assert :ok == on_insert(0, @data)

    assert_receive %Change{op: :insert, lsn: 0, struct: %AccountMetrics{patterns: ["a"]}}
  end

  test "on_update/3 broadcasts the updated patterns" do
    assert :ok == on_update(0, @data, %{@data | "patterns" => ["b"]})

    assert_receive %Change{
      op: :update,
      old_struct: %AccountMetrics{patterns: ["a"]},
      struct: %AccountMetrics{patterns: ["b"]}
    }
  end

  test "on_delete/2 broadcasts the deleted patterns" do
    assert :ok == on_delete(0, @data)

    assert_receive %Change{op: :delete, old_struct: %AccountMetrics{account_id: @account_id}}
  end
end
