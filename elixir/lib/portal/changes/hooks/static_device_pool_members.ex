defmodule Portal.Changes.Hooks.StaticDevicePoolMembers do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    member = struct_from_params(Portal.StaticDevicePoolMember, data)
    change = %Change{lsn: lsn, op: :insert, struct: member}

    PubSub.Changes.broadcast(member.account_id, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_member = struct_from_params(Portal.StaticDevicePoolMember, old_data)
    member = struct_from_params(Portal.StaticDevicePoolMember, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_member, struct: member}

    PubSub.Changes.broadcast(member.account_id, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    member = struct_from_params(Portal.StaticDevicePoolMember, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: member}

    PubSub.Changes.broadcast(member.account_id, change)
  end
end
