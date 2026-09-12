defmodule Portal.Changes.Hooks.PostureDevices do
  @moduledoc """
  Shared hooks for the device rows a posture provider syncs.

  A sync rewrites every row it reports, so a change is published only under
  the identifiers a client device can match it on, and a rewrite that touched
  nothing but the sync bookkeeping is not published at all.
  """

  alias Portal.{Changes.Change, Devices.Posture, PubSub}
  import Portal.SchemaHelpers

  @bookkeeping ~w[synced_at updated_at]

  def on_insert(schema, lsn, data) do
    row = struct_from_params(schema, data)
    broadcast(row, Posture.row_keys(row), %Change{lsn: lsn, op: :insert, struct: row})
  end

  def on_update(schema, lsn, old_data, data) do
    if bookkeeping_only_change?(old_data, data) do
      :ok
    else
      old_row = struct_from_params(schema, old_data)
      row = struct_from_params(schema, data)
      change = %Change{lsn: lsn, op: :update, old_struct: old_row, struct: row}
      broadcast(row, Enum.uniq(Posture.row_keys(old_row) ++ Posture.row_keys(row)), change)
    end
  end

  def on_delete(schema, lsn, old_data) do
    row = struct_from_params(schema, old_data)
    broadcast(row, Posture.row_keys(row), %Change{lsn: lsn, op: :delete, old_struct: row})
  end

  defp broadcast(row, keys, change) do
    PubSub.Changes.broadcast_posture_rows(row.account_id, keys, change)
  end

  defp bookkeeping_only_change?(old_data, data) when is_map(old_data) and is_map(data) do
    changed = for {key, value} <- data, Map.get(old_data, key) != value, do: key
    Enum.all?(changed, &(&1 in @bookkeeping))
  end

  defp bookkeeping_only_change?(_old_data, _data), do: false
end
