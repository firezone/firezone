defmodule Domain.Events.Hooks.Clients do
  @behaviour Domain.Events.Hooks
  alias Domain.PubSub

  @impl true
  def on_insert(_data), do: :ok

  # Soft-delete
  @impl true
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at} = _data)
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(_old_data, %{"id" => client_id} = _data) do
    PubSub.Client.broadcast(client_id, :updated)
  end

  @impl true
  def on_delete(%{"id" => client_id} = _old_data) do
    PubSub.Client.disconnect(client_id)
  end
end
