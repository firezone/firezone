defmodule Portal.Changes.Hooks.AccountMetricSets do
  @behaviour Portal.Changes.Hooks
  alias Portal.{AccountMetricSet, Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    metric_set = struct_from_params(AccountMetricSet, data)
    change = %Change{lsn: lsn, op: :insert, struct: metric_set}

    PubSub.Changes.broadcast(metric_set.account_id, :account_metric_sets, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_metric_set = struct_from_params(AccountMetricSet, old_data)
    metric_set = struct_from_params(AccountMetricSet, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_metric_set, struct: metric_set}

    PubSub.Changes.broadcast(metric_set.account_id, :account_metric_sets, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    metric_set = struct_from_params(AccountMetricSet, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: metric_set}

    PubSub.Changes.broadcast(metric_set.account_id, :account_metric_sets, change)
  end
end
