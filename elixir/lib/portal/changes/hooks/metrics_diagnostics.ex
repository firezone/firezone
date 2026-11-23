defmodule Portal.Changes.Hooks.MetricsDiagnostics do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, MetricsDiagnostics, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    diagnostics = struct_from_params(MetricsDiagnostics, data)
    change = %Change{lsn: lsn, op: :insert, struct: diagnostics}

    PubSub.Changes.broadcast(diagnostics.account_id, :metrics_diagnostics, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_diagnostics = struct_from_params(MetricsDiagnostics, old_data)
    diagnostics = struct_from_params(MetricsDiagnostics, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_diagnostics, struct: diagnostics}

    PubSub.Changes.broadcast(diagnostics.account_id, :metrics_diagnostics, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    diagnostics = struct_from_params(MetricsDiagnostics, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: diagnostics}

    PubSub.Changes.broadcast(diagnostics.account_id, :metrics_diagnostics, change)
  end
end
