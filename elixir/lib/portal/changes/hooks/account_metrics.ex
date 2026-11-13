defmodule Portal.Changes.Hooks.AccountMetrics do
  @behaviour Portal.Changes.Hooks
  alias Portal.{AccountMetrics, Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    metrics = struct_from_params(AccountMetrics, data)
    change = %Change{lsn: lsn, op: :insert, struct: metrics}

    PubSub.Changes.broadcast(metrics.account_id, :account_metrics, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_metrics = struct_from_params(AccountMetrics, old_data)
    metrics = struct_from_params(AccountMetrics, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_metrics, struct: metrics}

    PubSub.Changes.broadcast(metrics.account_id, :account_metrics, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    metrics = struct_from_params(AccountMetrics, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: metrics}

    PubSub.Changes.broadcast(metrics.account_id, :account_metrics, change)
  end
end
