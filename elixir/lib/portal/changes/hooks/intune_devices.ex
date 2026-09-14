defmodule Portal.Changes.Hooks.IntuneDevices do
  @moduledoc """
  Hooks for the device rows a Microsoft Intune sync writes.

  A sync rewrites every row it reports, so a rewrite that touched nothing but
  the sync bookkeeping is not published at all.
  """

  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @bookkeeping ~w[synced_at updated_at]

  @impl true
  def on_insert(lsn, data) do
    device = struct_from_params(Portal.Intune.Device, data)
    change = %Change{lsn: lsn, op: :insert, struct: device}

    PubSub.Changes.broadcast(device.account_id, :intune_devices, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    if bookkeeping_only_change?(old_data, data) do
      :ok
    else
      old_device = struct_from_params(Portal.Intune.Device, old_data)
      device = struct_from_params(Portal.Intune.Device, data)
      change = %Change{lsn: lsn, op: :update, old_struct: old_device, struct: device}
      PubSub.Changes.broadcast(device.account_id, :intune_devices, change)
    end
  end

  @impl true
  def on_delete(lsn, old_data) do
    device = struct_from_params(Portal.Intune.Device, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: device}

    PubSub.Changes.broadcast(device.account_id, :intune_devices, change)
  end

  defp bookkeeping_only_change?(old_data, data) when is_map(old_data) and is_map(data) do
    changed = for {key, value} <- data, Map.get(old_data, key) != value, do: key
    Enum.all?(changed, &(&1 in @bookkeeping))
  end

  defp bookkeeping_only_change?(_old_data, _data), do: false
end
