defmodule Domain.Events.Hooks.Accounts do
  alias Domain.PubSub
  require Logger

  def on_insert(_data) do
    :ok
  end

  def on_update(old_data, data) do
    with {:ok, account_id} <- Map.fetch(data, "id"),
         {:ok, old_config} <- Map.fetch(old_data, "config"),
         {:ok, config} <- Map.fetch(data, "config") do
      if old_config != config do
        broadcast(account_id, :config_changed)
      else
        :ok
      end
    else
      :error ->
        Logger.error("Expected keys not found in data",
          old_data: inspect(old_data),
          data: inspect(data)
        )

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
