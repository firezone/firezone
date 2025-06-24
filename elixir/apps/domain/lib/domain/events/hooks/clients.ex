defmodule Domain.Events.Hooks.Clients do
  @behaviour Domain.Events.Hooks
  alias Domain.PubSub
  alias Domain.Clients

  @impl true
  def on_insert(_data), do: :ok

  # Soft-delete
  @impl true
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at} = _data)
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(_old_data, data) do
    client = Domain.struct_from_params(Clients.Client, data)
    PubSub.Client.broadcast(client.id, {:updated, client})
  end

  @impl true
  def on_delete(%{"id" => client_id} = _old_data) do
    PubSub.Client.disconnect(client_id)
  end
end
