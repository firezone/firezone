defmodule Domain.Events.Hooks.ActorGroups do
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

  def subscribe_to_policies(actor_group_id) do
    actor_group_id
    |> policies_topic()
    |> PubSub.subscribe()
  end

  def unsubscribe_from_policies(actor_group_id) do
    actor_group_id
    |> policies_topic()
    |> PubSub.unsubscribe()
  end

  def broadcast_to_policies(actor_group_id, payload) do
    actor_group_id
    |> policies_topic()
    |> PubSub.broadcast(payload)
  end

  defp policies_topic(actor_group_id) do
    "actor_group_policies:#{actor_group_id}"
  end
end
