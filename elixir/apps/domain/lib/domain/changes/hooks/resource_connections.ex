defmodule Domain.Changes.Hooks.ResourceConnections do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, PubSub}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    connection = struct_from_params(Domain.Resources.Connection, data)
    change = %Change{lsn: lsn, op: :insert, struct: connection}

    PubSub.Account.broadcast(connection.account_id, change)
  end

  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    connection = struct_from_params(Domain.Resources.Connection, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: connection}

    delete_flows_for(connection)

    PubSub.Account.broadcast(connection.account_id, change)
  end

  # Inline function from Domain.Flows
  defp delete_flows_for(%Domain.Resources.Connection{} = connection) do
    import Ecto.Query

    from(f in Domain.Flow, as: :flows)
    |> where([flows: f], f.account_id == ^connection.account_id)
    |> where([flows: f], f.resource_id == ^connection.resource_id)
    |> join(:inner, [flows: f], g in Domain.Gateway,
      on: f.gateway_id == g.id,
      as: :gateway
    )
    |> where([gateway: g], g.site_id == ^connection.site_id)
    |> Domain.Safe.unscoped()
    |> Domain.Safe.delete_all()
  end
end
