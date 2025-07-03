defmodule Domain.Events.Hooks.Resources do
  @behaviour Domain.Events.Hooks
  alias Domain.{PubSub, Resources}

  @impl true
  def on_insert(data) do
    resource = Domain.struct_from_params(Resources.Resource, data)
    PubSub.Account.broadcast(resource.account_id, {:created, resource})
  end

  @impl true

  # Soft-delete - process as delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Update - breaking updates are handled by the consumer
  def on_update(old_data, data) do
    old_resource = Domain.struct_from_params(Resources.Resource, old_data)
    resource = Domain.struct_from_params(Resources.Resource, data)
    PubSub.Account.broadcast(resource.account_id, {:updated, old_resource, resource})
  end

  @impl true
  def on_delete(old_data) do
    resource = Domain.struct_from_params(Resources.Resource, old_data)
    PubSub.Account.broadcast(resource.account_id, {:deleted, resource})
  end
end
