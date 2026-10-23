defmodule Portal.Changes.Hooks.DeviceActors do
  @moduledoc """
  Broadcast-only: nothing reacts to a device gaining or losing an actor yet.
  Pool membership for offline devices and the Devices page read the table
  directly, and sessions are torn down by the token and actor hooks.
  """
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    device_actor = struct_from_params(Portal.DeviceActor, data)
    change = %Change{lsn: lsn, op: :insert, struct: device_actor}

    PubSub.Changes.broadcast(device_actor.account_id, :device_actors, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_device_actor = struct_from_params(Portal.DeviceActor, old_data)
    device_actor = struct_from_params(Portal.DeviceActor, data)

    change = %Change{
      lsn: lsn,
      op: :update,
      old_struct: old_device_actor,
      struct: device_actor
    }

    PubSub.Changes.broadcast(device_actor.account_id, :device_actors, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    device_actor = struct_from_params(Portal.DeviceActor, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: device_actor}

    PubSub.Changes.broadcast(device_actor.account_id, :device_actors, change)
  end
end
