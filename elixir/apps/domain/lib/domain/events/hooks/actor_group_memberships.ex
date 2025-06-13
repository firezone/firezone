defmodule Domain.Events.Hooks.ActorGroupMemberships do
  alias Domain.{Events, Flows, Policies, PubSub, Repo}

  def on_insert(%{"actor_id" => actor_id, "group_id" => group_id} = _data) do
    broadcast_access(:allow, actor_id, group_id)
    broadcast(:create, actor_id, group_id)
  end

  def on_update(_old_data, _data), do: :ok

  def on_delete(%{"actor_id" => actor_id, "group_id" => group_id} = _old_data) do
    Task.start(fn ->
      {:ok, _flows} = Flows.expire_flows_for(actor_id, group_id)
      broadcast_access(:reject, actor_id, group_id)
      broadcast(:delete, actor_id, group_id)
    end)

    :ok
  end

  def broadcast(action, actor_id, group_id) do
    payload = {:"#{action}_membership", actor_id, group_id}
    topic = Events.Hooks.Actors.memberships_topic(actor_id)

    :ok = PubSub.broadcast(topic, payload)
  end

  defp broadcast_access(action, actor_id, group_id) do
    # TODO: There's likely a bug here - need to omit disabled policies too
    Policies.Policy.Query.not_deleted()
    |> Policies.Policy.Query.by_actor_group_id(group_id)
    |> Repo.all()
    |> Enum.each(fn policy ->
      payload = {:"#{action}_access", policy.id, policy.actor_group_id, policy.resource_id}
      :ok = Events.Hooks.Actors.broadcast_to_policies(actor_id, payload)
    end)
  end
end
