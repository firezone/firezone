defmodule Domain.Changes.Hooks.GatewayGroups do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, Gateways, PubSub}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  # Soft-delete
  @impl true
  def on_update(lsn, %{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(lsn, old_data)
  end

  # Regular update
  def on_update(lsn, old_data, data) do
    old_gateway_group = struct_from_params(Gateways.Group, old_data)
    gateway_group = struct_from_params(Gateways.Group, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_gateway_group, struct: gateway_group}

    PubSub.Account.broadcast(gateway_group.account_id, change)
  end

  @impl true

  # Deleting a gateway group will delete the associated resource connection, where
  # we handle removing it from the client's resource list.
  def on_delete(_lsn, _old_data), do: :ok
end
