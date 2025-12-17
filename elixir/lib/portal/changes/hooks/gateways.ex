defmodule Portal.Changes.Hooks.Gateways do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, Gateway, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    gateway = struct_from_params(Gateway, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: gateway}

    PubSub.Account.broadcast(gateway.account_id, change)
  end
end
