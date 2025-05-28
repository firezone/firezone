defmodule Domain.Events.Hooks.Accounts do
  alias Domain.PubSub
  require Logger

  def on_insert(_data) do
    :ok
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

  # No unsubscribe needed - account deletions destroy any subscribed entities

  defp broadcast(account_id, event) do
    PubSub.broadcast("accounts:#{account_id}", event)
  end
end
