defmodule Portal.Changes.Hooks.Memberships do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    membership = struct_from_params(Portal.Membership, data)
    change = %Change{lsn: lsn, op: :insert, struct: membership}

    PubSub.Account.broadcast(membership.account_id, change)
  end

  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    membership = struct_from_params(Portal.Membership, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: membership}

    PubSub.Account.broadcast(membership.account_id, change)
  end
end
