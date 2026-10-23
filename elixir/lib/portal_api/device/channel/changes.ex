defmodule PortalAPI.Device.Channel.Changes do
  @moduledoc """
  What a device channel does with a row change in its account.

  Every change replicated for the account reaches every channel in it. The
  inbound half reacts to authorizations the device received being deleted
  and to served resources changing shape; the outbound half, where the
  device consumes resources, to everything that decides what it may reach.
  A device's own row and its account concern both halves.
  """

  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 3]

  alias Portal.{Cache, Changes.Change, Device, Devices, SchemaHelpers}
  alias Portal.Authentication.Credential
  alias PortalAPI.Device.Channel.{Core, Inbound, Outbound}

  @posture_provider_schemas [
    Portal.Intune.PostureProvider,
    Portal.Iru.PostureProvider,
    Portal.Defender.PostureProvider,
    Portal.Santa.PostureProvider,
    Portal.SentinelOne.PostureProvider,
    Portal.Sophos.PostureProvider
  ]

  @doc "Applies a change to the channel, once; a change already seen by LSN is ignored."
  @spec handle(Change.t(), Phoenix.Socket.t()) ::
          {:noreply, Phoenix.Socket.t()} | {:stop, term(), Phoenix.Socket.t()}
  def handle(%Change{lsn: lsn} = change, socket) do
    last_lsn = Map.get(socket.assigns, :last_lsn, 0)

    if lsn > last_lsn do
      case handle_change(change, socket) do
        {:noreply, socket} -> {:noreply, assign(socket, :last_lsn, lsn)}
        result -> result
      end
    else
      {:noreply, socket}
    end
  end

  # ACTORS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Actor{id: actor_id, is_disabled: false},
           struct: %Portal.Actor{id: actor_id, is_disabled: true}
         },
         %{assigns: %{subject: %{actor: %{id: actor_id}}}} = socket
       ) do
    if Core.outbound?(socket), do: Core.disconnect(socket), else: {:noreply, socket}
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.Actor{id: actor_id}},
         %{assigns: %{subject: %{actor: %{id: actor_id}}}} = socket
       ) do
    if Core.outbound?(socket), do: Core.disconnect(socket), else: {:noreply, socket}
  end

  # X.509 AUTH PROVIDERS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.X509.AuthProvider{id: auth_provider_id, is_disabled: false},
           struct: %Portal.X509.AuthProvider{id: auth_provider_id, is_disabled: true}
         },
         %{assigns: %{subject: %{credential: %Credential.X509{auth_provider_id: auth_provider_id}}}} =
           socket
       ) do
    Core.disconnect(socket)
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.X509.AuthProvider{id: auth_provider_id}},
         %{assigns: %{subject: %{credential: %Credential.X509{auth_provider_id: auth_provider_id}}}} =
           socket
       ) do
    Core.disconnect(socket)
  end

  # ACCOUNTS

  # Disabling an account is broadcast as an account deletion. Unlike
  # token-backed credentials, X.509 credentials have no ClientToken row for
  # the account hook to delete, so every channel for the account is cut here.
  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.Account{id: account_id}},
         %{assigns: %{device: %{account_id: account_id}}} = socket
       ) do
    if Core.outbound?(socket), do: Core.disconnect_account(socket), else: {:noreply, socket}
  end

  # Fail closed should an account-disabled update ever be broadcast directly
  # instead of being normalized to the delete above.
  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Account{is_disabled: false},
           struct: %Portal.Account{is_disabled: true}
         },
         socket
       ) do
    if Core.outbound?(socket), do: Core.disconnect_account(socket), else: {:noreply, socket}
  end

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Account{} = old_account,
           struct: %Portal.Account{} = account
         },
         socket
       ) do
    account = SchemaHelpers.merge_broadcast(Core.account(socket), account)
    socket = Core.put_account(socket, account)

    # A gateway learns its account's slug from init, so it is sent again.
    socket =
      if old_account.slug != account.slug and not Core.outbound?(socket) do
        Core.reinitialize(socket)
      else
        socket
      end

    if Core.outbound?(socket) do
      if old_account.config != account.config do
        device = %{Core.device(socket) | account: account}
        :ok = push(socket, "config_changed", %{interface: PortalAPI.Client.Views.Interface.render(device)})
      end

      if Portal.Account.device_posture_enabled?(old_account) !=
           Portal.Account.device_posture_enabled?(account) do
        Outbound.refresh_posture_rows(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # MEMBERSHIPS

  defp handle_change(
         %Change{op: :insert, struct: %Portal.Membership{actor_id: actor_id}},
         %{assigns: %{device: %{actor_id: id}}} = socket
       )
       when id == actor_id do
    if Core.outbound?(socket) do
      {:noreply, socket} =
        Cache.Client.add_membership(socket.assigns.cache, Core.device(socket), socket.assigns.subject)
        |> Outbound.push_resource_updates(socket)

      {:noreply, Core.track_presence(socket)}
    else
      {:noreply, socket}
    end
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.Membership{actor_id: actor_id} = membership},
         %{assigns: %{device: %{actor_id: id}}} = socket
       )
       when id == actor_id do
    if Core.outbound?(socket) do
      {:noreply, socket} =
        Cache.Client.delete_membership(
          socket.assigns.cache,
          membership,
          Core.device(socket),
          socket.assigns.subject
        )
        |> Outbound.push_resource_updates(socket)

      {:noreply, Core.track_presence(socket)}
    else
      {:noreply, socket}
    end
  end

  # THIS DEVICE

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Device{id: device_id} = old_device,
           struct: %Device{id: device_id} = device
         },
         %{assigns: %{device: %{id: device_id} = current}} = socket
       ) do
    socket = Core.put_device(socket, Device.merge_broadcast(current, device))

    socket =
      if old_device.ipv4 != device.ipv4 or old_device.ipv6 != device.ipv6 do
        Core.reinitialize(socket)
      else
        socket
      end

    # Verification can change the list of allowed resources.
    if Core.outbound?(socket) and old_device.verified_at != device.verified_at do
      Cache.Client.recompute_connectable_resources(
        socket.assigns.cache,
        Core.device(socket),
        socket.assigns.subject
      )
      |> Outbound.push_resource_updates(socket)
    else
      {:noreply, socket}
    end
  end

  # Deleting a device does not necessarily delete its token, so the channel
  # stops on its own and the device has to reconnect.
  defp handle_change(
         %Change{op: :delete, old_struct: %Device{id: device_id}},
         %{assigns: %{device: %{id: device_id}}} = socket
       ) do
    {:stop, :shutdown, socket}
  end

  # SITES

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Site{name: old_name},
           struct: %Portal.Site{name: name} = site
         },
         socket
       )
       when old_name != name do
    if Core.outbound?(socket) do
      Cache.Client.update_resources_with_site_name(
        socket.assigns.cache,
        site,
        Core.device(socket),
        socket.assigns.subject
      )
      |> Outbound.push_resource_updates(socket)
    else
      {:noreply, socket}
    end
  end

  # POLICIES

  defp handle_change(%Change{op: :insert, struct: %Portal.Policy{} = policy}, socket) do
    if Core.outbound?(socket) do
      Cache.Client.add_policy(socket.assigns.cache, policy, Core.device(socket), socket.assigns.subject)
      |> Outbound.push_resource_updates(socket)
    else
      {:noreply, socket}
    end
  end

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Policy{
             resource_id: old_resource_id,
             group_id: old_group_id,
             conditions: old_conditions,
             postures: old_postures
           },
           struct: %Portal.Policy{
             resource_id: resource_id,
             group_id: group_id,
             conditions: conditions,
             postures: postures,
             is_disabled: is_disabled
           }
         } = change,
         socket
       )
       when old_resource_id != resource_id or old_group_id != group_id or
              old_conditions != conditions or old_postures != postures do
    # A breaking update is a delete followed by an insert, which keeps the
    # cache honest at the cost of the odd redundant pair of pushes.
    {:noreply, socket} = handle_change(%{change | op: :delete}, socket)

    if is_disabled do
      {:noreply, socket}
    else
      handle_change(%{change | op: :insert}, socket)
    end
  end

  # Any other update, a description say, only refreshes the cached row.
  defp handle_change(
         %Change{op: :update, old_struct: %Portal.Policy{}, struct: %Portal.Policy{} = policy},
         socket
       ) do
    if Core.outbound?(socket) do
      Cache.Client.update_policy(socket.assigns.cache, policy)
      |> Outbound.push_resource_updates(socket)
    else
      {:noreply, socket}
    end
  end

  defp handle_change(%Change{op: :delete, old_struct: %Portal.Policy{} = policy}, socket) do
    if Core.outbound?(socket) do
      Cache.Client.delete_policy(socket.assigns.cache, policy, Core.device(socket), socket.assigns.subject)
      |> Outbound.push_resource_updates(socket)
    else
      {:noreply, socket}
    end
  end

  # POLICY AUTHORIZATIONS

  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Portal.PolicyAuthorization{receiving_device_id: device_id} = pa
         },
         %{assigns: %{device: %{id: device_id}}} = socket
       ) do
    Inbound.reject_access(socket, pa)
  end

  # On the v3 protocol the initiating side keeps the pool as its route to the
  # peer, so it gets the same reject_access when the authorization goes away
  # and asks the portal again on the next flow. Authorizations cascade on
  # device and policy deletes, so a deleted target or a revoked policy both
  # end up here.
  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Portal.PolicyAuthorization{initiating_device_id: device_id} = pa
         },
         %{assigns: %{device: %{id: device_id}}} = socket
       ) do
    if Core.outbound?(socket) and Core.protocol_version(socket) >= 3 and not expired?(pa) do
      push(socket, "reject_access", %{client_id: pa.receiving_device_id, resource_id: pa.resource_id})
    end

    {:noreply, socket}
  end

  # SITE ASSIGNMENTS OF THIS DEVICE

  defp handle_change(
         %Change{op: op, struct: struct, old_struct: old_struct},
         %{assigns: %{device: %{id: device_id}}} = socket
       )
       when op in [:insert, :delete] and
              (is_map(struct) and :erlang.map_get(:__struct__, struct) == Portal.SiteDevice and
                 :erlang.map_get(:device_id, struct) == device_id) or
              (is_map(old_struct) and :erlang.map_get(:__struct__, old_struct) == Portal.SiteDevice and
                 :erlang.map_get(:device_id, old_struct) == device_id) do
    # What the device serves changed: its presence says so, and on the
    # unified protocol its served view is sent again.
    socket = socket |> Core.reload_site_devices() |> Core.track_presence()

    if Core.protocol(socket).kind() == :device do
      push(socket, "sites_served_changed", Core.served_view(socket))
    end

    {:noreply, socket}
  end

  # RESOURCES

  defp handle_change(
         %Change{op: :insert, struct: %Portal.Resource{} = resource},
         socket
       ) do
    push_local_resource(socket, resource)
    {:noreply, socket}
  end

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Resource{} = old_resource,
           struct: %Portal.Resource{} = resource
         },
         socket
       ) do
    push_local_resource(socket, resource, old_resource)

    # The serving side can follow a filter change; anything else about how the
    # resource is addressed resets every pair on it so the initiators ask again.
    cond do
      old_resource.address != resource.address or old_resource.ip_stack != resource.ip_stack or
          old_resource.type != resource.type ->
        :ok = Inbound.reject_resource(socket, resource.id)

      old_resource.filters != resource.filters and resource.type != :device_pool and
          old_resource.type != :device_pool ->
        :ok = Inbound.resource_updated(socket, resource)

      true ->
        :ok
    end

    if Core.outbound?(socket) do
      Outbound.maybe_push_resource_filters_updated(socket, resource, old_resource.filters, resource.filters)

      {:ok, _added, _removed_ids, cache} =
        result =
        Cache.Client.update_resource(
          socket.assigns.cache,
          resource,
          Core.device(socket),
          socket.assigns.subject
        )

      for addresses <- Cache.Client.removed_member_addresses(socket.assigns.cache, cache) do
        Outbound.push_device_access_denied(socket, addresses)
      end

      Outbound.push_resource_updates(result, socket)
    else
      {:noreply, socket}
    end
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.Resource{} = resource},
         socket
       ) do
    if Core.protocol(socket).kind() == :device and Core.serves_site?(socket, resource.site_id) do
      push(socket, "local_resource_deleted", resource.id)
    end

    {:noreply, socket}
  end

  # OTHER DEVICES, members of a pool this one may use

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Device{type: :client},
           struct: %Device{type: :client} = device
         },
         socket
       ) do
    if Core.outbound?(socket) do
      Cache.Client.handle_member_device_update(socket.assigns.cache, device, socket.assigns.subject)
      |> Outbound.push_resource_updates(socket)
    else
      {:noreply, socket}
    end
  end

  defp handle_change(%Change{op: :delete, old_struct: %Device{type: :client} = device}, socket) do
    if Core.outbound?(socket) do
      {:ok, denied, added, removed_ids, cache} =
        Cache.Client.handle_member_device_delete(socket.assigns.cache, device)

      Outbound.push_device_access_denied(socket, denied)
      Outbound.push_resource_updates({:ok, added, removed_ids, cache}, socket)
    else
      {:noreply, socket}
    end
  end

  # POSTURE ROWS
  #
  # Every provider row change in the account arrives here, so only one that
  # carries an identifier of this device is acted on.
  defp handle_change(%Change{} = change, socket) do
    if Core.outbound?(socket) and
         (posture_provider_toggled?(change) or
            (posture_row_change?(change) and concerns_device?(change, Core.device(socket)))) do
      Outbound.refresh_posture_rows(socket)
    else
      {:noreply, socket}
    end
  end

  # On the unified protocol a device serving the resource's site is told the
  # resource's new shape, or that it now serves it, or that it stopped.
  defp push_local_resource(socket, resource, old_resource \\ nil) do
    if Core.protocol(socket).kind() == :device do
      serves_now? = Core.serves_site?(socket, resource.site_id)
      served_before? = old_resource && Core.serves_site?(socket, old_resource.site_id)

      cond do
        serves_now? ->
          push(socket, "local_resource_created_or_updated", PortalAPI.Device.Views.Served.render_resource(resource))

        served_before? ->
          push(socket, "local_resource_deleted", resource.id)

        true ->
          :ok
      end
    end

    :ok
  end

  # A disabled provider's rows count as absent, and the rows themselves do not change.
  defp posture_provider_toggled?(%Change{op: :update, old_struct: %module{} = old, struct: %module{} = new}) do
    module in @posture_provider_schemas and old.is_disabled != new.is_disabled
  end

  defp posture_provider_toggled?(%Change{}), do: false

  defp posture_row_change?(%Change{struct: %module{}}), do: module in Devices.Posture.schemas()
  defp posture_row_change?(%Change{old_struct: %module{}}), do: module in Devices.Posture.schemas()
  defp posture_row_change?(%Change{}), do: false

  defp concerns_device?(%Change{old_struct: old_row, struct: row}, device) do
    row_keys =
      Enum.flat_map([old_row, row], &if(is_nil(&1), do: [], else: Devices.Posture.row_keys(&1)))

    device_keys = Devices.Posture.device_keys(device) ++ Devices.Posture.entra_keys(device.posture)

    Enum.any?(row_keys, &(&1 in device_keys))
  end

  defp expired?(%Portal.PolicyAuthorization{expires_at: nil}), do: false

  defp expired?(%Portal.PolicyAuthorization{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end
end
