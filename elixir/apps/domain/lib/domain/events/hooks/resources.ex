defmodule Domain.Events.Hooks.Resources do
  alias Domain.Events.Hooks.Accounts
  alias Domain.PubSub

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

  def on_update(_old_data, _data) do
    :ok
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
