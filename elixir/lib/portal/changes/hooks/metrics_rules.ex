defmodule Portal.Changes.Hooks.MetricsRules do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, MetricsRule, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    rule = struct_from_params(MetricsRule, data)

    PubSub.Changes.broadcast_metrics_rule(%Change{lsn: lsn, op: :insert, struct: rule})
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_rule = struct_from_params(MetricsRule, old_data)
    rule = struct_from_params(MetricsRule, data)

    PubSub.Changes.broadcast_metrics_rule(%Change{lsn: lsn, op: :update, old_struct: old_rule, struct: rule})
  end

  @impl true
  def on_delete(lsn, old_data) do
    rule = struct_from_params(MetricsRule, old_data)

    PubSub.Changes.broadcast_metrics_rule(%Change{lsn: lsn, op: :delete, old_struct: rule})
  end
end
