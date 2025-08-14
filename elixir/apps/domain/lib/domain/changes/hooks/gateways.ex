defmodule Domain.Changes.Hooks.Gateways do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, Flows, Gateways, PubSub}
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
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    gateway = struct_from_params(Gateways.Gateway, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: gateway}

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Flows.delete_flows_for(gateway)

    PubSub.Account.broadcast(gateway.account_id, change)
  end
end
