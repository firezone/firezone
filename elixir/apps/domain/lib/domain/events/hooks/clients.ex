defmodule Domain.Events.Hooks.Clients do
  alias Domain.PubSub
  alias Domain.Clients.{Client, Presence}
  alias Domain.Events

  def on_insert(_data) do
    :ok
  end

  # Soft-delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at} = _data)
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(_old_data, %{"id" => client_id} = _data) do
    broadcast(client_id, :updated)
  end

  def on_delete(%{"id" => client_id} = _old_data) do
    disconnect_client(client_id)
  end

  def connect(%Client{} = client) do
    with {:ok, _} <-
           Presence.track(
             self(),
             Events.Hooks.Accounts.clients_presence_topic(client.account_id),
             client.id,
             %{
               online_at: System.system_time(:second)
             }
           ),
         {:ok, _} <-
           Presence.track(
             self(),
             Events.Hooks.Actors.clients_presence_topic(client.actor_id),
             client.id,
             %{}
           ) do
      :ok = PubSub.subscribe(topic(client.id))
      :ok = Events.Hooks.Accounts.subscribe_to_clients(client.account_id)
      :ok
    end
  end

  ### PubSub

  def broadcast(client_id, payload) do
    client_id
    |> topic()
    |> PubSub.broadcast(payload)
  end

  defp topic(client_id), do: "clients:#{client_id}"

  defp disconnect_client(client_id) do
    broadcast(client_id, "disconnect")
  end
end
