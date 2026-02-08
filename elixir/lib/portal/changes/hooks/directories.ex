defmodule Portal.Changes.Hooks.Directories do
  @moduledoc """
  Hooks for handling changes to directory-related tables. For simplicity and because an account
  will nearly always have only a handful of directories, we broadcast a generic "directories"
  message to notify subscribers.
  """

  @behaviour Portal.Changes.Hooks
  alias Portal.PubSub

  def on_insert(_lsn, %{"account_id" => account_id}), do: broadcast(account_id)
  def on_update(_lsn, _old_data, %{"account_id" => account_id}), do: broadcast(account_id)
  def on_delete(_lsn, %{"account_id" => account_id}), do: broadcast(account_id)

  # Used to notify the Settings -> Directory Sync LiveView
  defp broadcast(account_id) do
    PubSub.Changes.broadcast(account_id, :directories_changed)
  end
end
