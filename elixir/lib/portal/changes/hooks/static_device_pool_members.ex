defmodule Portal.Changes.Hooks.StaticDevicePoolMembers do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  alias __MODULE__.Database
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    member = struct_from_params(Portal.StaticDevicePoolMember, data)
    change = %Change{lsn: lsn, op: :insert, struct: member}

    PubSub.Changes.broadcast(member.account_id, :static_device_pool_members, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_member = struct_from_params(Portal.StaticDevicePoolMember, old_data)
    member = struct_from_params(Portal.StaticDevicePoolMember, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_member, struct: member}

    PubSub.Changes.broadcast(member.account_id, :static_device_pool_members, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    member = struct_from_params(Portal.StaticDevicePoolMember, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: member}

    # The removed device is no longer a responder in this pool, so revoke the
    # authorizations that let peers reach it through the pool resource. Deleting
    # these rows makes the removed device receive `reject_access` and stops it
    # re-hydrating the stale authorizations from its `init` on reconnect. The
    # initiating side is handled separately via the member-delete broadcast.
    Database.delete_responder_authorizations_for_member(member)

    PubSub.Changes.broadcast(member.account_id, :static_device_pool_members, change)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, PolicyAuthorization, StaticDevicePoolMember}

    def delete_responder_authorizations_for_member(%StaticDevicePoolMember{} = member) do
      from(f in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^member.account_id)
      |> where([policy_authorizations: f], f.resource_id == ^member.resource_id)
      |> where([policy_authorizations: f], f.receiving_device_id == ^member.device_id)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
