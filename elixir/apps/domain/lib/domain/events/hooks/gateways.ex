defmodule Domain.Events.Hooks.Gateways do
  alias Domain.PubSub
  alias Domain.Gateways
  alias Domain.Events

  def on_insert(_data) do
    :ok
  end

  # Soft-delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at} = _data)
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(_old_data, _data) do
    :ok
  end

  def on_delete(%{"id" => gateway_id} = _old_data) do
    disconnect(gateway_id)
  end

  def connect(%Gateways.Gateway{} = gateway) do
    with {:ok, _} <-
           Gateways.Presence.track(
             self(),
             Events.Hooks.GatewayGroups.presence_topic(gateway.group_id),
             gateway.id,
             %{}
           ),
         {:ok, _} <-
           Gateways.Presence.track(
             self(),
             Events.Hooks.Accounts.gateways_presence_topic(gateway.account_id),
             gateway.id,
             %{
               online_at: System.system_time(:second)
             }
           ) do
      :ok = PubSub.subscribe(topic(gateway.id))
      :ok
    end
  end

  def broadcast(gateway_id, payload) do
    gateway_id
    |> topic()
    |> PubSub.broadcast(payload)
  end

  defp disconnect(gateway_id) do
    gateway_id
    |> broadcast("disconnect")
  end

  defp topic(gateway_id) do
    "gateways:#{gateway_id}"
  end
end
