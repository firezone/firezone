defmodule Portal.Changes.Hooks.SiteDevices do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub, SiteDevice}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    site_device = struct_from_params(SiteDevice, data)
    change = %Change{lsn: lsn, op: :insert, struct: site_device}
    PubSub.Changes.broadcast(site_device.account_id, :site_devices, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_site_device = struct_from_params(SiteDevice, old_data)
    site_device = struct_from_params(SiteDevice, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_site_device, struct: site_device}
    PubSub.Changes.broadcast(site_device.account_id, :site_devices, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    site_device = struct_from_params(SiteDevice, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: site_device}
    PubSub.Changes.broadcast(site_device.account_id, :site_devices, change)
  end
end
