defmodule Domain.Changes.Hooks.Tokens do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, PubSub, Tokens}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true

  # updates for email tokens have no side effects
  def on_update(_lsn, %{"type" => "email"}, _data), do: :ok

  def on_update(_lsn, _old_data, %{"type" => "email"}), do: :ok

  # Soft-delete - process as delete
  def on_update(lsn, %{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(lsn, old_data)
  end

  # Regular update
  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    token = struct_from_params(Tokens.Token, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: token}

    # Disconnect all sockets using this token
    disconnect_socket(token)

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Domain.Flows.delete_flows_for(token)

    PubSub.Account.broadcast(token.account_id, change)
  end

  # This is a special message that disconnects all sockets using this token,
  # such as for LiveViews.
  defp disconnect_socket(token) do
    topic = Domain.Tokens.socket_id(token.id)
    payload = %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
    Domain.PubSub.broadcast(topic, payload)
  end
end
