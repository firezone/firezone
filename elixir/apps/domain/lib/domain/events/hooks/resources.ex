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

  # Breaking updates
  # This is a special case - we need to delete related flows because connectivity has changed
  def on_update(
        %{
          "type" => old_type,
          "ip_stack" => old_ip_stack,
          "address" => old_address,
          "filters" => old_filters
        } = old_data,
        %{
          "type" => type,
          "ip_stack" => ip_stack,
          "address" => address,
          "filters" => filters
        } = data
      )
      when old_type != type or
             old_ip_stack != ip_stack or
             old_address != address or
             old_filters != filters do
    old_resource = SchemaHelpers.struct_from_params(Resources.Resource, old_data)
    resource = SchemaHelpers.struct_from_params(Resources.Resource, data)

    PubSub.Account.broadcast(resource.account_id, {:updated, old_resource, resource})

    # Delete flows for the resource since connectivity has changed
    Domain.Flows.delete_flows_for(resource)
  end

  # Regular update
  def on_update(old_data, data) do
    old_resource = SchemaHelpers.struct_from_params(Resources.Resource, old_data)
    resource = SchemaHelpers.struct_from_params(Resources.Resource, data)
    PubSub.Account.broadcast(resource.account_id, {:updated, old_resource, resource})
  end

  @impl true
  def on_delete(old_data) do
    resource = SchemaHelpers.struct_from_params(Resources.Resource, old_data)
    PubSub.Account.broadcast(resource.account_id, {:deleted, resource})

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Domain.Flows.delete_flows_for(resource)
  end
end
