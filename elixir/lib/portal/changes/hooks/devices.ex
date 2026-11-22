defmodule Portal.Changes.Hooks.Devices do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  alias __MODULE__.Database
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    device = struct_from_params(Portal.Device, data)
    change = %Change{lsn: lsn, op: :insert, struct: device}

    PubSub.Changes.broadcast(device.account_id, :devices, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    # Connect flushes rewrite only the latest-session columns; broadcasting
    # them would fan every connect out to all subscribers in the account.
    # A gateway moving on or off `/device/v1` joins or leaves pools, so it is broadcast.
    if latest_session_only_change?(old_data, data) and not gateway_device_v1_changed?(old_data, data) do
      :ok
    else
      old_device = struct_from_params(Portal.Device, old_data)
      device = struct_from_params(Portal.Device, data)
      change = %Change{lsn: lsn, op: :update, old_struct: old_device, struct: device}

      if gateway_device_v1_changed?(old_data, data) and not device.last_seen_device_v1 do
        Database.delete_pool_policy_authorizations_toward(device)
      end

      # Unverifying a client device - delete associated policy_authorizations
      if device.type == :client and
           not is_nil(old_device.verified_at) and is_nil(device.verified_at) do
        Database.delete_policy_authorizations_for_device(device)
      end

      PubSub.Changes.broadcast(device.account_id, :devices, change)
    end
  end

  @impl true
  def on_delete(lsn, old_data) do
    device = struct_from_params(Portal.Device, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: device}

    Database.remove_device_from_pools(device)

    PubSub.Changes.broadcast(device.account_id, :devices, change)
  end

  defp latest_session_only_change?(old_data, data) when is_map(old_data) and is_map(data) do
    changed = for {key, value} <- data, Map.get(old_data, key) != value, do: key
    changed != [] and Enum.all?(changed, &(&1 in Portal.Device.latest_session_columns()))
  end

  defp latest_session_only_change?(_old_data, _data), do: false

  defp gateway_device_v1_changed?(%{"type" => "gateway"} = old_data, %{"type" => "gateway"} = data),
    do: Map.get(old_data, "last_seen_device_v1") != Map.get(data, "last_seen_device_v1")

  defp gateway_device_v1_changed?(_old_data, _data), do: false

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

    def delete_pool_policy_authorizations_toward(%Portal.Device{} = device) do
      from(f in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^device.account_id)
      |> where([policy_authorizations: f], f.receiving_device_id == ^device.id)
      |> join(:inner, [policy_authorizations: f], r in Portal.Resource,
        on: r.account_id == f.account_id and r.id == f.resource_id,
        as: :resources
      )
      |> where([resources: r], r.type == :device_pool)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def remove_device_from_pools(%Portal.Device{} = device) do
      from(r in Portal.Resource, as: :resources)
      |> where([resources: r], r.account_id == ^device.account_id and r.type == :device_pool)
      |> where(
        [resources: r],
        fragment("jsonb_exists(? #> '{device,value}', ?)", r.device_membership_criteria, ^device.id)
      )
      |> update([resources: r],
        set: [
          device_membership_criteria:
            fragment(
              "jsonb_set(?, '{device,value}', (? #> '{device,value}') - ?)",
              r.device_membership_criteria,
              r.device_membership_criteria,
              ^device.id
            ),
          updated_at: ^DateTime.utc_now()
        ]
      )
      |> Safe.unscoped()
      |> Safe.update_all([])
    end
  end
end
