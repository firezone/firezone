defmodule Portal.Changes.Hooks.Resources do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  alias __MODULE__.Database
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    resource = struct_from_params(Portal.Resource, data)
    change = %Change{lsn: lsn, op: :insert, struct: resource}

    PubSub.Changes.broadcast(resource.account_id, :resources, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_resource = struct_from_params(Portal.Resource, old_data)
    resource = struct_from_params(Portal.Resource, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_resource, struct: resource}

    # Breaking updates

    # This is a special case - we need to delete related policy_authorizations because connectivity has changed
    # Gateway _does_ handle resource filter changes so we don't need to delete policy_authorizations
    # for those changes - they're processed by the Gateway channel process.

    # The Gateway channel will process these policy_authorization deletions and re-authorize the policy_authorization.
    # However, the gateway will also react to the resource update and send reject_access
    # so that the Gateway's state is updated correctly, and the client can create a new policy_authorization.
    if old_resource.site_id != resource.site_id or
         old_resource.ip_stack != resource.ip_stack or
         old_resource.type != resource.type or
         old_resource.address != resource.address do
      Database.delete_policy_authorizations_for(resource)
    end

    if resource.type == :device_pool and
         old_resource.device_membership_criteria != resource.device_membership_criteria do
      Database.delete_policy_authorizations_for_non_members(resource)
    end

    PubSub.Changes.broadcast(resource.account_id, :resources, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    resource = struct_from_params(Portal.Resource, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: resource}

    PubSub.Changes.broadcast(resource.account_id, :resources, change)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Resource.DeviceMembershipCriteria

    # Inline function from Portal.PolicyAuthorizations
    def delete_policy_authorizations_for(%Portal.Resource{} = resource) do
      resource
      |> policy_authorizations()
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_policy_authorizations_for_non_members(
          %Portal.Resource{
            device_membership_criteria: %DeviceMembershipCriteria{
              field: :id,
              op: :in,
              value: {:literal, device_ids}
            }
          } = resource
        ) do
      resource
      |> policy_authorizations()
      |> where([policy_authorizations: f], f.receiving_device_id not in ^device_ids)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_policy_authorizations_for_non_members(
          %Portal.Resource{
            device_membership_criteria: %DeviceMembershipCriteria{
              field: :actor_id,
              op: :eq,
              value: {:subject, :actor_id}
            }
          } = resource
        ) do
      resource
      |> policy_authorizations()
      |> join(:inner, [policy_authorizations: f], r in Portal.Device,
        on: r.account_id == f.account_id and r.id == f.receiving_device_id,
        as: :receiver
      )
      |> join(:inner, [policy_authorizations: f], i in Portal.Device,
        on: i.account_id == f.account_id and i.id == f.initiating_device_id,
        as: :initiator
      )
      |> where([receiver: r, initiator: i], r.actor_id != i.actor_id)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    defp policy_authorizations(%Portal.Resource{} = resource) do
      from(f in Portal.PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^resource.account_id)
      |> where([policy_authorizations: f], f.resource_id == ^resource.id)
    end
  end
end
