defmodule Portal.Changes.Hooks.DeviceTokens do
  @behaviour Portal.Changes.Hooks
  alias Portal.PG
  alias Portal.Changes.Change
  alias Portal.PubSub
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    token = struct_from_params(Portal.DeviceToken, data)
    change = %Change{lsn: lsn, op: :insert, struct: token}
    broadcast(token, change)
  end

  @impl true
  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    token = struct_from_params(Portal.DeviceToken, old_data)
    PG.deliver(token.id, :disconnect)

    change = %Change{lsn: lsn, op: :delete, old_struct: token}
    broadcast(token, change)
  end

  defp broadcast(%Portal.DeviceToken{auth_provider_id: nil}, _change), do: :ok

  defp broadcast(token, change) do
    PubSub.Changes.broadcast(token.account_id, :client_tokens, change)
  end
end
