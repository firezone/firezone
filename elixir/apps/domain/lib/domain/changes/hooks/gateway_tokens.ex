defmodule Domain.Changes.Hooks.GatewayTokens do
  @behaviour Domain.Changes.Hooks
  alias Domain.PubSub
  import Domain.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(_lsn, old_data) do
    token = struct_from_params(Domain.GatewayToken, old_data)

    # Disconnect all sockets using this token
    disconnect_socket(token)
  end

  defp disconnect_socket(token) do
    topic = Domain.Sockets.socket_id(token.id)
    payload = %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
    PubSub.broadcast(topic, payload)
  end
end
