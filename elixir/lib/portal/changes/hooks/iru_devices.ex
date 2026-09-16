defmodule Portal.Changes.Hooks.IruDevices do
  @moduledoc """
  Hooks for the device rows an Iru sync writes.
  """

  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    device = struct_from_params(Portal.Iru.Device, data)
    change = %Change{lsn: lsn, op: :insert, struct: device}

    PubSub.Changes.broadcast(device.account_id, :iru_devices, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_device = struct_from_params(Portal.Iru.Device, old_data)
    device = struct_from_params(Portal.Iru.Device, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_device, struct: device}

    PubSub.Changes.broadcast(device.account_id, :iru_devices, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    device = struct_from_params(Portal.Iru.Device, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: device}

    PubSub.Changes.broadcast(device.account_id, :iru_devices, change)
  end
end
