defmodule Domain.Changes.Hooks.Tokens do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Flows, PubSub, Tokens}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true

  # updates for email and relay_group tokens have no side effects
  def on_update(_lsn, %{"type" => "email"}, _data), do: :ok

  def on_update(_lsn, _old_data, %{"type" => "email"}), do: :ok

  def on_update(_lsn, %{"type" => "relay_group"}, _data), do: :ok

  def on_update(_lsn, _old_data, %{"type" => "relay_group"}), do: :ok

  # Soft-delete - process as delete
  def on_update(lsn, %{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(lsn, old_data)
  end

  # Regular update
  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(_lsn, old_data) do
    token = struct_from_params(Tokens.Token, old_data)

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Flows.delete_flows_for(token)

    # We don't need to broadcast deleted tokens since the disconnect_socket/1
    # function will handle any disconnects for us directly.

    # Disconnect all sockets using this token
    disconnect_socket(token)
  end

  # This is a special message that disconnects all sockets using this token,
  # such as for LiveViews.
  defp disconnect_socket(token) do
    topic = Domain.Tokens.socket_id(token.id)
    payload = %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
    PubSub.broadcast(topic, payload)
  end
end
