defmodule Portal.Changes.Hooks.Devices do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  alias __MODULE__.Database
  import Portal.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(lsn, old_data, data) do
    old_device = struct_from_params(Portal.Device, old_data)
    device = struct_from_params(Portal.Device, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_device, struct: device}

    # Unverifying a client device - delete associated policy_authorizations
    if device.type == :client and
         not is_nil(old_device.verified_at) and is_nil(device.verified_at) do
      Database.delete_policy_authorizations_for_device(device)
    end

    PubSub.Changes.broadcast(device.account_id, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    device = struct_from_params(Portal.Device, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: device}

    PubSub.Changes.broadcast(device.account_id, change)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, PolicyAuthorization}

    def delete_policy_authorizations_for_device(%Portal.Device{} = device) do
      from(f in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^device.account_id)
      |> where([policy_authorizations: f], f.initiating_device_id == ^device.id)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
