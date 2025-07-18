defmodule Domain.Events.Hooks.Resources do
  @behaviour Domain.Events.Hooks
  alias Domain.{SchemaHelpers, PubSub, Resources}

  @impl true
  def on_insert(data) do
    resource = SchemaHelpers.struct_from_params(Resources.Resource, data)
    PubSub.Account.broadcast(resource.account_id, {:created, resource})
  end

  @impl true

  # Soft-delete - process as delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(old_data, data) do
    old_resource = SchemaHelpers.struct_from_params(Resources.Resource, old_data)
    resource = SchemaHelpers.struct_from_params(Resources.Resource, data)

    # Breaking updates
    # This is a special case - we need to delete related flows because connectivity has changed
    # Gateway _does_ handle resource filter changes so we don't need to delete flows
    # for those changes
    if old_resource.ip_stack != resource.ip_stack or
         old_resource.type != resource.type or
         old_resource.address != resource.address do
      Domain.Flows.delete_flows_for(resource)
    end

    PubSub.Account.broadcast(resource.account_id, {:updated, old_resource, resource})
  end

  @impl true
  def on_delete(old_data) do
    resource = SchemaHelpers.struct_from_params(Resources.Resource, old_data)

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Domain.Flows.delete_flows_for(resource)

    PubSub.Account.broadcast(resource.account_id, {:deleted, resource})
  end
end
