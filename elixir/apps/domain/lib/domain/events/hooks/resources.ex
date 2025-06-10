defmodule Domain.Events.Hooks.Resources do
  alias Domain.Events.Hooks.Accounts
  alias Domain.{Flows, PubSub}

  def on_insert(%{"id" => resource_id, "account_id" => account_id} = _data) do
    payload = {:create_resource, resource_id}
    broadcast(resource_id, payload)
    Accounts.broadcast_to_resources(account_id, payload)
  end

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
    # Directly broadcast to subscribed pids to remove the flow
    Task.async(fn ->
      {:ok, _flows} = Flows.expire_flows_for_resource_id(resource_id)

      payload = {:delete_resource, resource_id}
      broadcast(resource_id, payload)
      Accounts.broadcast_to_resources(account_id, payload)

      payload = {:create_resource, resource_id}
      broadcast(resource_id, payload)
      Accounts.broadcast_to_resources(account_id, payload)
    end)

    :ok
  end

  # Non-breaking update - for non-addressability changes - e.g. name, description, etc.
  def on_update(_old_data, %{"id" => resource_id, "account_id" => account_id} = _data) do
    payload = {:update_resource, resource_id}
    broadcast(resource_id, payload)
    Accounts.broadcast_to_resources(account_id, payload)
  end

  def on_delete(%{"id" => resource_id, "account_id" => account_id} = _old_data) do
    payload = {:delete_resource, resource_id}
    broadcast(resource_id, payload)
    Accounts.broadcast_to_resources(account_id, payload)
  end

  def subscribe(resource_id) do
    resource_id
    |> topic()
    |> PubSub.subscribe()
  end

  def unsubscribe(resource_id) do
    resource_id
    |> topic()
    |> PubSub.unsubscribe()
  end

  def broadcast(resource_id, payload) do
    resource_id
    |> topic()
    |> PubSub.broadcast(payload)
  end

  defp topic(resource_id) do
    "resource:#{resource_id}"
  end
end
