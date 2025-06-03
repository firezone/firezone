defmodule Domain.Events.Hooks.ActorGroupMemberships do
  alias Domain.{Events, Policies, PubSub}

  def on_insert(%{"actor_id" => actor_id, "group_id" => group_id} = _data) do
    broadcast(:create, actor_id, group_id)
  end

  def on_update(_old_data, _data) do
    :ok
  end

  def on_delete(%{"actor_id" => actor_id, "group_id" => group_id} = _old_data) do
    broadcast(:delete, actor_id, group_id)
  end

  def broadcast(action, actor_id, group_id) do
    payload = {:"#{action}_membership", actor_id, group_id}
    topic = Events.Hooks.Actors.memberships_topic(actor_id)

    :ok = PubSub.broadcast(topic, payload)

    # TODO: This is an n+1 query; refactor with a cached lookup table on the client channel
    :ok = Policies.broadcast_access_events_for(action, actor_id, group_id)
  end
end
