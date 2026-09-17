defmodule Portal.Changes.Hooks.Memberships do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  alias __MODULE__.Database
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    membership = struct_from_params(Portal.Membership, data)
    change = %Change{lsn: lsn, op: :insert, struct: membership}

    PubSub.Changes.broadcast(membership.account_id, :memberships, change)
  end

  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    membership = struct_from_params(Portal.Membership, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: membership}

    Database.delete_policy_authorizations_through_group_pools(membership)

    PubSub.Changes.broadcast(membership.account_id, :memberships, change)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Resource.DeviceMembershipCriteria
    alias Portal.Safe

    # The actor's devices leave every pool that holds the group's devices.
    def delete_policy_authorizations_through_group_pools(%Portal.Membership{} = membership) do
      criteria = DeviceMembershipCriteria.actor_group(membership.group_id)

      from(f in Portal.PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^membership.account_id)
      |> join(:inner, [policy_authorizations: f], r in Portal.Resource,
        on: r.account_id == f.account_id and r.id == f.resource_id,
        as: :resource
      )
      |> join(:inner, [policy_authorizations: f], d in Portal.Device,
        on: d.account_id == f.account_id and d.id == f.receiving_device_id,
        as: :receiver
      )
      |> where([resource: r], r.type == :device_pool and r.device_membership_criteria == ^criteria)
      |> where([receiver: d], d.actor_id == ^membership.actor_id)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
