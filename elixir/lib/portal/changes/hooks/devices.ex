defmodule Portal.Changes.Hooks.Devices do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PG, PubSub}
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
    old_device = struct_from_params(Portal.Device, old_data)
    device = struct_from_params(Portal.Device, data)

    if public_key_rotated?(old_device, device) do
      disconnect_peers_of_rotated_device(device)
    end

    # Connect flushes rewrite only the latest-session columns; broadcasting
    # them would fan every connect out to all subscribers in the account.
    if latest_session_only_change?(old_data, data) do
      :ok
    else
      change = %Change{lsn: lsn, op: :update, old_struct: old_device, struct: device}

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

    if device.type == :client do
      Database.remove_device_from_pools(device)
    end

    PubSub.Changes.broadcast(device.account_id, :devices, change)
  end

  defp latest_session_only_change?(old_data, data) when is_map(old_data) and is_map(data) do
    changed = for {key, value} <- data, Map.get(old_data, key) != value, do: key
    changed != [] and Enum.all?(changed, &(&1 in Portal.Device.latest_session_columns()))
  end

  defp latest_session_only_change?(_old_data, _data), do: false

  defp public_key_rotated?(%Portal.Device{public_key: old_key}, %Portal.Device{
         public_key: new_key,
         last_seen_at: %DateTime{}
       }) do
    not is_nil(old_key) and not is_nil(new_key) and old_key != new_key
  end

  defp public_key_rotated?(_old_device, _device), do: false

  defp disconnect_peers_of_rotated_device(%Portal.Device{} = device) do
    {_count, authorizations} = Database.delete_prior_session_policy_authorizations(device)

    authorizations
    |> Enum.map(fn
      %{initiating_device_id: initiating_device_id, receiving_device_id: peer_id}
      when initiating_device_id == device.id ->
        peer_id

      %{initiating_device_id: peer_id} ->
        peer_id
    end)
    |> Enum.uniq()
    |> Enum.each(&PG.deliver(&1, {:pubkey_changed, device.id}))
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, PolicyAuthorization}

    # Authorizations the new session already created (inserted after it connected) stay.
    def delete_prior_session_policy_authorizations(%Portal.Device{} = device) do
      now = DateTime.utc_now()

      from(f in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^device.account_id)
      |> where(
        [policy_authorizations: f],
        f.initiating_device_id == ^device.id or f.receiving_device_id == ^device.id
      )
      |> where([policy_authorizations: f], f.expires_at > ^now)
      |> where([policy_authorizations: f], f.inserted_at < ^device.last_seen_at)
      |> select([policy_authorizations: f], %{
        initiating_device_id: f.initiating_device_id,
        receiving_device_id: f.receiving_device_id
      })
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_policy_authorizations_for_device(%Portal.Device{} = device) do
      from(f in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^device.account_id)
      |> where([policy_authorizations: f], f.initiating_device_id == ^device.id)
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
