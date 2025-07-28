defmodule Domain.Changes.Hooks.ResourceConnections do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, Flows, Resources, PubSub}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    connection = struct_from_params(Resources.Connection, data)
    change = %Change{lsn: lsn, op: :insert, struct: connection}

    PubSub.Account.broadcast(connection.account_id, change)
  end

  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    connection = struct_from_params(Resources.Connection, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: connection}

    Flows.delete_flows_for(connection)

    PubSub.Account.broadcast(connection.account_id, change)
  end
end
