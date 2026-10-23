defmodule Portal.Changes.Hooks.SiteDevices do
  @moduledoc """
  Broadcast-only: assigning a device to a site, or removing it, is announced
  so the Sites page and the channels that route by site can react. Nothing
  reads it yet.
  """
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    site_device = struct_from_params(Portal.SiteDevice, data)
    change = %Change{lsn: lsn, op: :insert, struct: site_device}

    PubSub.Changes.broadcast(site_device.account_id, :site_devices, change)
  end

  # The row has no mutable columns.
  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    site_device = struct_from_params(Portal.SiteDevice, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: site_device}

    PubSub.Changes.broadcast(site_device.account_id, :site_devices, change)
  end
end
