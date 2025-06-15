defmodule Domain.Events.Hooks.Gateways do
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
  def on_update(_old_data, _data), do: :ok

  @impl true
  def on_delete(%{"id" => gateway_id} = _old_data) do
    PubSub.Gateway.disconnect(gateway_id)
  end
end
