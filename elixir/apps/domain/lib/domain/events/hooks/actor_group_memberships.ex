defmodule Domain.Events.Hooks.ActorGroupMemberships do
  @behaviour Domain.Events.Hooks
  alias Domain.{Flows, Policies, PubSub, Repo}

  @impl true
  def on_insert(%{"actor_id" => actor_id, "group_id" => group_id} = _data) do
    Task.start(fn ->
      :ok = PubSub.Actor.Memberships.broadcast(actor_id, {:create_membership, actor_id, group_id})
      broadcast_access(:allow, actor_id, group_id)
    end)

    :ok
  end

  @impl true
  def on_update(_old_data, _data), do: :ok

  @impl true
  def on_delete(
        %{"account_id" => account_id, "actor_id" => actor_id, "group_id" => group_id} = _old_data
      ) do
    Task.start(fn ->
      :ok = PubSub.Actor.Memberships.broadcast(actor_id, {:delete_membership, actor_id, group_id})
      broadcast_access(:reject, actor_id, group_id)

      # TODO: WAL
      # Broadcast flow side effects directly
      :ok = Flows.expire_flows_for(account_id, actor_id, group_id)
    end)

    :ok
  end

  defp broadcast_access(action, actor_id, group_id) do
    Policies.Policy.Query.not_deleted()
    |> Policies.Policy.Query.by_actor_group_id(group_id)
    |> Repo.all(checkout_timeout: 30_000)
    |> Enum.each(fn policy ->
      payload = {:"#{action}_access", policy.id, policy.actor_group_id, policy.resource_id}
      :ok = PubSub.Actor.Policies.broadcast(actor_id, payload)
    end)
  end
end
