defmodule Domain.Events.Hooks.ResourceConnections do
  @behaviour Domain.Events.Hooks
  alias Domain.{SchemaHelpers, Resources, PubSub}

  @impl true
  def on_insert(data) do
    connection = SchemaHelpers.struct_from_params(Resources.Connection, data)
    PubSub.Account.broadcast(connection.account_id, {:created, connection})
  end

  @impl true
  def on_update(_old_data, _data), do: :ok

  @impl true
  def on_delete(old_data) do
    connection = SchemaHelpers.struct_from_params(Resources.Connection, old_data)
    PubSub.Account.broadcast(connection.account_id, {:deleted, connection})
  end
end
