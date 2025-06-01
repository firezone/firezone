defmodule Domain.Events.Hooks.GatewayGroups do
  alias Domain.PubSub

  def on_insert(_data) do
    :ok
  end

  def on_update(_old_data, _data) do
    :ok
  end

  def on_delete(_old_data) do
    :ok
  end

  def subscribe(gateway_group_id) do
    gateway_group_id
    |> topic()
    |> PubSub.subscribe()
  end

  def subscribe_to_presence(gateway_group_id) do
    gateway_group_id
    |> presence_topic()
    |> PubSub.subscribe()
  end

  def unsubscribe(gateway_group_id) do
    gateway_group_id
    |> topic()
    |> PubSub.unsubscribe()
  end

  def presence_topic(gateway_group_id) do
    "presences:#{topic(gateway_group_id)}"
  end

  defp topic(gateway_group_id) do
    "group_gateways:#{gateway_group_id}"
  end
end
