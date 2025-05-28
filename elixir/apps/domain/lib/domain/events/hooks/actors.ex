defmodule Domain.Events.Hooks.Actors do
  alias Domain.PubSub

  def on_insert(_data) do
    :ok
  end

  def on_update(_old_data, _data) do
    :ok
  end

  def on_delete(_old_data) do
    :ok
  end

  def subscribe_to_clients_presence(actor_id) do
    actor_id
    |> clients_presence_topic()
    |> PubSub.subscribe()
  end

  def clients_presence_topic(actor_id) do
    "presences:#{clients_topic(actor_id)}"
  end

  defp clients_topic(actor_id) do
    "actor_clients:#{actor_id}"
  end
end
