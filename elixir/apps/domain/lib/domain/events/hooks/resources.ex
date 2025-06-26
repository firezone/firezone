defmodule Domain.Events.Hooks.Resources do
  @behaviour Domain.Events.Hooks
  alias Domain.{Flows, PubSub}

  @impl true
  def on_insert(%{"id" => resource_id, "account_id" => account_id} = _data) do
    payload = {:create_resource, resource_id}
    PubSub.Resource.broadcast(resource_id, payload)
    PubSub.Account.Resources.broadcast(account_id, payload)
  end

  @impl true

  # Soft-delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at} = _data)
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Breaking update - expire flows so that new flows are created
  def on_update(
        %{
          "type" => old_type,
          "address" => old_address,
          "filters" => old_filters,
          "ip_stack" => old_ip_stack
        } = _old_data,
        %{
          "type" => type,
          "address" => address,
          "filters" => filters,
          "ip_stack" => ip_stack,
          "id" => resource_id,
          "account_id" => account_id
        } = _data
      )
      when old_type != type or
             old_address != address or
             old_filters != filters or
             old_ip_stack != ip_stack do
    # TODO: WAL
    # Broadcast flow side effects directly
    Task.start(fn ->
      payload = {:delete_resource, resource_id}
      PubSub.Resource.broadcast(resource_id, payload)
      PubSub.Account.Resources.broadcast(account_id, payload)

      payload = {:create_resource, resource_id}
      PubSub.Resource.broadcast(resource_id, payload)
      PubSub.Account.Resources.broadcast(account_id, payload)

      :ok = Flows.expire_flows_for_resource_id(account_id, resource_id)
    end)

    :ok
  end

  # Non-breaking update - for non-addressability changes - e.g. name, description, etc.
  def on_update(_old_data, %{"id" => resource_id, "account_id" => account_id} = _data) do
    payload = {:update_resource, resource_id}
    PubSub.Resource.broadcast(resource_id, payload)
    PubSub.Account.Resources.broadcast(account_id, payload)
  end

  @impl true
  def on_delete(%{"id" => resource_id, "account_id" => account_id} = _old_data) do
    payload = {:delete_resource, resource_id}
    PubSub.Resource.broadcast(resource_id, payload)
    PubSub.Account.Resources.broadcast(account_id, payload)
  end
end
