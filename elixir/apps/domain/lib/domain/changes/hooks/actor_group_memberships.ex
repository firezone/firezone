defmodule Domain.Changes.Hooks.ActorGroupMemberships do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Actors, Changes.Change, PubSub}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    membership = struct_from_params(Actors.Membership, data)
    change = %Change{lsn: lsn, op: :insert, struct: membership}

    PubSub.Account.broadcast(membership.account_id, change)
  end

  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    membership = struct_from_params(Actors.Membership, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: membership}

    PubSub.Account.broadcast(membership.account_id, change)
  end
end
