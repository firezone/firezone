defmodule Domain.Changes.Hooks.PortalSessions do
  @behaviour Domain.Changes.Hooks
  alias Domain.PubSub
  import Domain.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(_lsn, old_data) do
    session = struct_from_params(Domain.PortalSession, old_data)

    # Disconnect all sockets using this portal session
    disconnect_socket(session)
  end

  # This is a special message that disconnects all sockets using this session,
  # such as for LiveViews.
  defp disconnect_socket(session) do
    topic = Domain.Sockets.socket_id(session.id)
    payload = %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
    PubSub.broadcast(topic, payload)
  end
end
