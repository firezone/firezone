defmodule Domain.Changes.Hooks.Resources do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, Flows, PubSub, Resources}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    resource = struct_from_params(Resources.Resource, data)
    change = %Change{lsn: lsn, op: :insert, struct: resource}

    PubSub.Account.broadcast(resource.account_id, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_resource = struct_from_params(Resources.Resource, old_data)
    resource = struct_from_params(Resources.Resource, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_resource, struct: resource}

    # Breaking updates

    # This is a special case - we need to delete related flows because connectivity has changed
    # Gateway _does_ handle resource filter changes so we don't need to delete flows
    # for those changes - they're processed by the Gateway channel pid.

    # The Gateway channel will process these flow deletions and re-authorize the flow.
    # However, the gateway will also react to the resource update and send reject_access
    # so that the Gateway's state is updated correctly, and the client can create a new flow.
    if old_resource.ip_stack != resource.ip_stack or
         old_resource.type != resource.type or
         old_resource.address != resource.address do
      Flows.delete_flows_for(resource)
    end

    PubSub.Account.broadcast(resource.account_id, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    resource = struct_from_params(Resources.Resource, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: resource}

    PubSub.Account.broadcast(resource.account_id, change)
  end
end
