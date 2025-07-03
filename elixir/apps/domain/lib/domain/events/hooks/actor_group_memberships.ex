defmodule Domain.Events.Hooks.ActorGroupMemberships do
  @behaviour Domain.Events.Hooks
  alias Domain.{Actors, PubSub}

  @impl true
  def on_insert(data) do
    membership = Domain.struct_from_params(Actors.Membership, data)
    PubSub.Account.broadcast(membership.account_id, {:created, membership})
  end

  @impl true
  def on_update(_old_data, _data), do: :ok

  @impl true
  def on_delete(old_data) do
    membership = Domain.struct_from_params(Actors.Membership, old_data)
    PubSub.Account.broadcast(membership.account_id, {:deleted, membership})
  end
end
