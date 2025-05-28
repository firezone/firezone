defmodule Domain.Events.Hooks.Tokens do
  def on_insert(_data) do
    :ok
  end

  # updates for email tokens have no side effects
  def on_update(%{"type" => "email"}, _data), do: :ok
  def on_update(_old_data, %{"type" => "email"}), do: :ok

  # Soft-delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update - not expected to happen in normal operation
  def on_update(_old_data, _new_data) do
    :ok
  end

  def on_delete(%{"id" => token_id}) do
    broadcast_disconnect(token_id)
  end

  defp broadcast_disconnect(token_id) do
    topic = Domain.Tokens.socket_id(token_id)
    payload = %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
    Phoenix.PubSub.broadcast(Domain.PubSub, topic, payload)
  end
end
