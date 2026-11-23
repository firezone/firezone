defmodule Portal.Changes.Hooks.MetricsDiagnosticsTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.MetricsDiagnostics
  alias Portal.{Changes.Change, MetricsDiagnostics, PubSub}

  @account_id "00000000-0000-0000-0000-000000000000"
  @actor_id "00000000-0000-0000-0000-000000000001"

  @data %{
    "account_id" => @account_id,
    "actor_id" => @actor_id,
    "expires_at" => "2026-11-30T00:00:00.000000Z"
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :metrics_diagnostics)
  end

  test "on_insert/2 broadcasts the new diagnostics" do
    assert :ok == on_insert(0, @data)

    assert_receive %Change{op: :insert, lsn: 0, struct: %MetricsDiagnostics{actor_id: @actor_id}}
  end

  test "on_update/3 broadcasts the updated diagnostics" do
    assert :ok == on_update(0, @data, %{@data | "expires_at" => "2026-12-07T00:00:00.000000Z"})

    assert_receive %Change{
      op: :update,
      old_struct: %MetricsDiagnostics{expires_at: ~U[2026-11-30 00:00:00.000000Z]},
      struct: %MetricsDiagnostics{expires_at: ~U[2026-12-07 00:00:00.000000Z]}
    }
  end

  test "on_delete/2 broadcasts the deleted diagnostics" do
    assert :ok == on_delete(0, @data)

    assert_receive %Change{op: :delete, old_struct: %MetricsDiagnostics{actor_id: @actor_id}}
  end
end
