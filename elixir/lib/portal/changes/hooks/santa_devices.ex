defmodule Portal.Changes.Hooks.SantaDevices do
  @behaviour Portal.Changes.Hooks
  alias Portal.Changes.Hooks.PostureDevices

  @impl true
  def on_insert(lsn, data), do: PostureDevices.on_insert(Portal.Santa.Device, lsn, data)

  @impl true
  def on_update(lsn, old_data, data), do: PostureDevices.on_update(Portal.Santa.Device, lsn, old_data, data)

  @impl true
  def on_delete(lsn, old_data), do: PostureDevices.on_delete(Portal.Santa.Device, lsn, old_data)
end
