defmodule Portal.Changes.Hooks.Groups do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    group = struct_from_params(Portal.Group, data)
    change = %Change{lsn: lsn, op: :insert, struct: group}
    PubSub.Changes.broadcast(group.account_id, change)
  end

  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    group = struct_from_params(Portal.Group, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: group}
    PubSub.Changes.broadcast(group.account_id, change)
  end
end
