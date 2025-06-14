defmodule Domain.Events.Hooks.Accounts do
  alias Domain.PubSub
  require Logger

  def on_insert(_data), do: :ok

  # Account disabled - disconnect clients
  def on_update(
        %{"disabled_at" => nil} = _old_data,
        %{"disabled_at" => disabled_at, "id" => account_id} = _data
      )
      when not is_nil(disabled_at) do
    disconnect_clients(account_id)
  end

  def on_update(%{"config" => old_config}, %{"config" => config, "id" => account_id}) do
    if old_config != config do
      broadcast(account_id, :config_changed)
    else
      :ok
    end
  end

  def on_delete(_old_data) do
    :ok
  end

  def subscribe(account_id) do
    PubSub.subscribe("accounts:#{account_id}")
  end

  def subscribe_to_clients(account_id) do
    account_id
    |> clients_topic()
    |> PubSub.subscribe()
  end

  def subscribe_to_resources(account_id) do
    account_id
    |> resources_topic()
    |> PubSub.subscribe()
  end

  def subscribe_to_policies(account_id) do
    account_id
    |> policies_topic()
    |> PubSub.subscribe()
  end

  def subscribe_to_clients_presence(account_id) do
    account_id
    |> clients_presence_topic()
    |> PubSub.subscribe()
  end

  def subscribe_to_gateways_presence(account_id) do
    account_id
    |> gateways_presence_topic()
    |> PubSub.subscribe()
  end

  def clients_presence_topic(account_id) do
    "presences:#{clients_topic(account_id)}"
  end

  def clients_topic(account_id) do
    "account_clients:#{account_id}"
  end

  def gateways_presence_topic(account_id) do
    "presences:account_gateways:#{account_id}"
  end

  def broadcast_to_resources(account_id, payload) do
    account_id
    |> resources_topic()
    |> PubSub.broadcast(payload)
  end

  def broadcast_to_policies(account_id, payload) do
    account_id
    |> policies_topic()
    |> PubSub.broadcast(payload)
  end

  defp resources_topic(account_id) do
    "account_resources:#{account_id}"
  end

  defp policies_topic(account_id) do
    "account_policies:#{account_id}"
  end

  defp topic(account_id) do
    "accounts:#{account_id}"
  end

  defp broadcast(account_id, event) do
    account_id
    |> topic()
    |> PubSub.broadcast(event)
  end

  defp disconnect_clients(account_id) do
    account_id
    |> clients_topic()
    |> PubSub.broadcast("disconnect")
  end
end
