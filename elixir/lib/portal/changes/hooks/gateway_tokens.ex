defmodule Portal.Changes.Hooks.GatewayTokens do
  @behaviour Portal.Changes.Hooks
  alias Portal.Channels
  import Portal.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(_lsn, old_data) do
    token = struct_from_params(Portal.GatewayToken, old_data)
    Channels.send_to_token(token.id, :disconnect)
    :ok
  end
end
