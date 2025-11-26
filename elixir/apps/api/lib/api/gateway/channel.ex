defmodule API.Gateway.Channel do
  use API, :channel
  alias API.Gateway.Views
  alias __MODULE__.DB

  alias Domain.{
    Accounts,
    Cache,
    Changes.Change,
    Flows,
    Gateways,
    Auth,
    PubSub,
    Relays,
    Resources
  }

  alias Domain.Relays.Presence.Debouncer
  require Logger

  # The interval at which the flow cache is pruned.
  @prune_cache_every :timer.minutes(1)

  # All relayed connections are dropped when this expires, so use
  # a long expiration time to avoid frequent disconnections.
  @relay_credentials_expire_in_hours 90 * 24

  @impl true
  def join("gateway", _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def handle_info(:after_join, socket) do
    # Initialize the cache
    socket = assign(socket, cache: Cache.Gateway.hydrate(socket.assigns.gateway))
    Process.send_after(self(), :prune_cache, @prune_cache_every)

    # Track gateway's presence
    :ok = Gateways.Presence.connect(socket.assigns.gateway, socket.assigns.token_id)

    # Subscribe to all account updates
    :ok = PubSub.Account.subscribe(socket.assigns.gateway.account_id)

    # Return all connected relays for the account
    {:ok, relays} = select_relays(socket)
    :ok = Enum.each(relays, &Domain.Relays.subscribe_to_relay_presence/1)
    :ok = maybe_subscribe_for_relays_presence(relays, socket)

    account = DB.get_account_by_id!(socket.assigns.gateway.account_id)

    init(socket, account, relays)

    # Cache new stamp secrets
    socket = Debouncer.cache_stamp_secrets(socket, relays)

    {:noreply, socket}
  end

  def handle_info(:prune_cache, socket) do
    Process.send_after(self(), :prune_cache, @prune_cache_every)
    {:noreply, assign(socket, cache: Cache.Gateway.prune(socket.assigns.cache))}
  end

  # Called to actually push relays_presence with a disconnected relay to the gateway
  def handle_info({:push_leave, relay_id, stamp_secret, payload}, socket) do
    {:noreply, Debouncer.handle_leave(socket, relay_id, stamp_secret, payload, &push/3)}
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  def handle_info(%Change{lsn: lsn} = change, socket) do
    last_lsn = Map.get(socket.assigns, :last_lsn, 0)

    if lsn <= last_lsn do
      Logger.warning("Out of order or duplicate change received; ignoring",
        change: change,
        last_lsn: last_lsn
      )

      {:noreply, socket}
    else
      socket = assign(socket, last_lsn: lsn)
      handle_change(change, socket)
    end
  end

  ####################################
  #### Reacting to relay presence ####
  ####################################

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:relays:" <> relay_id,
          payload: %{leaves: leaves}
        },
        socket
      ) do
    if Map.has_key?(leaves, relay_id) do
      :ok = Domain.Relays.unsubscribe_from_relay_presence(relay_id)

      relay_credentials_expire_at = DateTime.utc_now() |> DateTime.add(90, :day)
      {:ok, relays} = select_relays(socket, [relay_id])
      :ok = maybe_subscribe_for_relays_presence(relays, socket)

      :ok =
        Enum.each(relays, fn relay ->
          # TODO: Why are we unsubscribing and subscribing again?
          :ok = Domain.Relays.unsubscribe_from_relay_presence(relay)
          :ok = Domain.Relays.subscribe_to_relay_presence(relay)
        end)

      payload = %{
        disconnected_ids: [relay_id],
        connected:
          Views.Relay.render_many(
            relays,
            socket.assigns.gateway.public_key,
            relay_credentials_expire_at
          )
      }

      socket = Debouncer.queue_leave(self(), socket, relay_id, payload)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:" <> _,
          payload: %{joins: joins}
        },
        socket
      )
      when map_size(joins) > 0 do
    {:ok, relays} = select_relays(socket)

    if length(relays) > 0 do
      relay_credentials_expire_at = DateTime.utc_now() |> DateTime.add(90, :day)

      :ok =
        Relays.unsubscribe_from_relays_presence_in_account(socket.assigns.gateway.account_id)

      :ok =
        Enum.each(relays, fn relay ->
          # TODO: Why are we unsubscribing and subscribing again?
          :ok = Relays.unsubscribe_from_relay_presence(relay)
          :ok = Relays.subscribe_to_relay_presence(relay)
        end)

      # Cache new stamp secrets
      socket = Debouncer.cache_stamp_secrets(socket, relays)

      # If a relay reconnects with a different stamp_secret, disconnect them immediately
      joined_ids = Map.keys(joins)

      {socket, disconnected_ids} =
        Debouncer.cancel_leaves_or_disconnect_immediately(
          socket,
          joined_ids,
          socket.assigns.gateway.account_id
        )

      push(socket, "relays_presence", %{
        disconnected_ids: disconnected_ids,
        connected:
          Views.Relay.render_many(
            relays,
            socket.assigns.gateway.public_key,
            relay_credentials_expire_at
          )
      })

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  ###########################
  #### Connection setup #####
  ###########################

  def handle_info(
        {{:ice_candidates, gateway_id}, client_id, candidates},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    push(socket, "ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info(
        {{:invalidate_ice_candidates, gateway_id}, client_id, candidates},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    push(socket, "invalidate_ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info(
        {{:authorize_flow, gateway_id}, {channel_pid, socket_ref}, payload},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    %{
      client: client,
      resource: %Cache.Cacheable.Resource{} = resource,
      flow_id: flow_id,
      authorization_expires_at: authorization_expires_at,
      ice_credentials: ice_credentials,
      preshared_key: preshared_key,
      subject: %Auth.Subject{} = subject
    } = payload

    ref =
      encode_ref(socket, {
        channel_pid,
        socket_ref,
        resource.id,
        preshared_key,
        ice_credentials
      })

    push(socket, "authorize_flow", %{
      ref: ref,
      resource: Views.Resource.render(resource),
      gateway_ice_credentials: ice_credentials.gateway,
      client: Views.Client.render(client, preshared_key),
      client_ice_credentials: ice_credentials.client,
      expires_at: DateTime.to_unix(authorization_expires_at, :second),
      subject: Views.Subject.render(subject)
    })

    cache =
      socket.assigns.cache
      |> Cache.Gateway.put(
        client.id,
        resource.id,
        flow_id,
        authorization_expires_at
      )

    {:noreply, assign(socket, cache: cache)}
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {{:allow_access, gateway_id}, {channel_pid, socket_ref}, attrs},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    %{
      client: client,
      resource: %Cache.Cacheable.Resource{} = resource,
      flow_id: flow_id,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload
    } = attrs

    case Resources.adapt_resource_for_version(resource, socket.assigns.gateway.last_seen_version) do
      nil ->
        {:noreply, socket}

      resource ->
        ref =
          encode_ref(
            socket,
            {channel_pid, socket_ref, resource.id}
          )

        push(socket, "allow_access", %{
          ref: ref,
          client_id: client.id,
          resource: Views.Resource.render(resource),
          expires_at: DateTime.to_unix(authorization_expires_at, :second),
          payload: payload,
          client_ipv4: client.ipv4,
          client_ipv6: client.ipv6
        })

        cache =
          socket.assigns.cache
          |> Cache.Gateway.put(
            client.id,
            resource.id,
            flow_id,
            authorization_expires_at
          )

        {:noreply, assign(socket, cache: cache)}
    end
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {{:request_connection, gateway_id}, {channel_pid, socket_ref}, attrs},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    %{
      client: client,
      resource: %Cache.Cacheable.Resource{} = resource,
      flow_id: flow_id,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload,
      client_preshared_key: preshared_key
    } = attrs

    case Resources.adapt_resource_for_version(resource, socket.assigns.gateway.last_seen_version) do
      nil ->
        {:noreply, socket}

      resource ->
        ref =
          encode_ref(
            socket,
            {channel_pid, socket_ref, resource.id}
          )

        push(socket, "request_connection", %{
          ref: ref,
          resource: Views.Resource.render(resource),
          client: Views.Client.render(client, payload, preshared_key),
          expires_at: DateTime.to_unix(authorization_expires_at, :second)
        })

        cache =
          socket.assigns.cache
          |> Cache.Gateway.put(
            client.id,
            resource.id,
            flow_id,
            authorization_expires_at
          )

        {:noreply, assign(socket, cache: cache)}
    end
  end

  # Helper to directly send reject_access in integration tests
  def handle_info(
        {{:reject_access, gateway_id}, client_id, resource_id},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})
    {:noreply, socket}
  end

  # Catch-all for messages we don't handle
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_in("flow_authorized", %{"ref" => signed_ref}, socket) do
    case decode_ref(socket, signed_ref) do
      {:ok,
       {
         channel_pid,
         socket_ref,
         resource_id,
         preshared_key,
         ice_credentials
       }} ->
        send(
          channel_pid,
          {
            :connect,
            socket_ref,
            resource_id,
            socket.assigns.gateway.group_id,
            socket.assigns.gateway.id,
            socket.assigns.gateway.public_key,
            socket.assigns.gateway.ipv4,
            socket.assigns.gateway.ipv6,
            preshared_key,
            ice_credentials
          }
        )

        {:reply, :ok, socket}

      {:error, :invalid_ref} ->
        Logger.error("Gateway replied with an invalid ref")
        {:reply, {:error, %{reason: :invalid_ref}}, socket}
    end
  end

  # DEPRECATED IN 1.4
  @impl true
  def handle_in(
        "connection_ready",
        %{
          "ref" => signed_ref,
          "gateway_payload" => payload
        },
        socket
      ) do
    case decode_ref(socket, signed_ref) do
      {:ok, {channel_pid, socket_ref, rid_bytes}} ->
        send(
          channel_pid,
          {:connect, socket_ref, rid_bytes, socket.assigns.gateway.public_key, payload}
        )

        {:reply, :ok, socket}

      {:error, :invalid_ref} ->
        Logger.error("Gateway replied with an invalid ref")
        {:reply, {:error, %{reason: :invalid_ref}}, socket}
    end
  end

  #####################################
  ##### Gateway-initiated actions #####
  #####################################

  def handle_in(
        "broadcast_ice_candidates",
        %{"candidates" => candidates, "client_ids" => client_ids},
        socket
      ) do
    :ok =
      Enum.each(client_ids, fn client_id ->
        PubSub.Account.broadcast(
          socket.assigns.gateway.account_id,
          {{:ice_candidates, client_id}, socket.assigns.gateway.id, candidates}
        )
      end)

    {:noreply, socket}
  end

  def handle_in(
        "broadcast_invalidated_ice_candidates",
        %{"candidates" => candidates, "client_ids" => client_ids},
        socket
      ) do
    :ok =
      Enum.each(client_ids, fn client_id ->
        PubSub.Account.broadcast(
          socket.assigns.gateway.account_id,
          {{:invalidate_ice_candidates, client_id}, socket.assigns.gateway.id, candidates}
        )
      end)

    {:noreply, socket}
  end

  # Catch-all for unknown messages
  def handle_in(message, payload, socket) do
    Logger.error("Unknown gateway message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  defp encode_ref(socket, tuple) do
    ref =
      tuple
      |> :erlang.term_to_binary()
      |> Base.url_encode64()

    key_base = socket.endpoint.config(:secret_key_base)
    Plug.Crypto.sign(key_base, "gateway_reply_ref", ref)
  end

  defp decode_ref(socket, signed_ref) do
    key_base = socket.endpoint.config(:secret_key_base)

    with {:ok, ref} <-
           Plug.Crypto.verify(key_base, "gateway_reply_ref", signed_ref, max_age: :infinity) do
      tuple =
        ref
        |> Base.url_decode64!()
        |> Plug.Crypto.non_executable_binary_to_term([:safe])

      {:ok, tuple}
    else
      {:error, :invalid} -> {:error, :invalid_ref}
    end
  end

  defp select_relays(socket, except_ids \\ []) do
    {:ok, relays} =
      Relays.all_connected_relays_for_account(socket.assigns.gateway.account_id, except_ids)

    location = {
      socket.assigns.gateway.last_seen_remote_ip_location_lat,
      socket.assigns.gateway.last_seen_remote_ip_location_lon
    }

    relays = Relays.load_balance_relays(location, relays)

    {:ok, relays}
  end

  defp init(socket, account, relays) do
    relay_credentials_expire_at =
      DateTime.utc_now() |> DateTime.add(@relay_credentials_expire_in_hours, :hour)

    push(socket, "init", %{
      authorizations: Views.Flow.render_many(socket.assigns.cache),
      account_slug: account.slug,
      interface: Views.Interface.render(socket.assigns.gateway),
      relays:
        Views.Relay.render_many(
          relays,
          socket.assigns.gateway.public_key,
          relay_credentials_expire_at
        ),
      # These aren't used but needed for API compatibility
      config: %{
        ipv4_masquerade_enabled: true,
        ipv6_masquerade_enabled: true
      }
    })
  end

  defp maybe_subscribe_for_relays_presence(relays, socket) do
    if length(relays) > 0 do
      :ok
    else
      Relays.subscribe_to_relays_presence_in_account(socket.assigns.gateway.account_id)
    end
  end

  ##########################################
  #### Handling changes from the domain ####
  ##########################################

  # ACCOUNTS

  # Resend init when config changes so that new slug may be applied
  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Accounts.Account{slug: old_slug},
           struct: %Accounts.Account{slug: slug} = account
         },
         socket
       )
       when old_slug != slug do
    {:ok, relays} = select_relays(socket)
    init(socket, account, relays)

    {:noreply, socket}
  end

  # FLOWS

  defp handle_change(
         %Change{
           op: :delete,
           old_struct:
             %Flows.Flow{gateway_id: gateway_id, client_id: client_id, resource_id: resource_id} =
               flow
         },
         %{
           assigns: %{gateway: %{id: gateway_id}}
         } = socket
       ) do
    socket.assigns.cache
    |> Cache.Gateway.reauthorize_deleted_flow(flow)
    |> case do
      {:ok, expires_at_unix, cache} ->
        Logger.info("Updating authorization expiration for deleted flow",
          deleted_flow: inspect(flow),
          new_expires_at: DateTime.from_unix!(expires_at_unix, :second)
        )

        push(
          socket,
          "access_authorization_expiry_updated",
          Views.Flow.render(flow, expires_at_unix)
        )

        {:noreply, assign(socket, cache: cache)}

      {:error, :unauthorized, cache} ->
        Logger.info("No authorizations remaining for deleted flow, revoking access",
          deleted_flow: inspect(flow)
        )

        # Note: There is an edge case here:
        #   - Client authorizes flow for resource
        #   - Client's websocket temporarily gets cut
        #   - Admin deletes the policy
        #   - We send reject_access to the gateway
        #   - Admin recreates the same policy (same access)
        #   - Client connection resumes
        #   - Client sees exactly the same resource list
        #   - Client now has lost the ability to recreate the flow because from its perspective, it is still connected
        #     to this gateway.
        #   - Packets to gateway are essentially blackholed until the client signs out and back in

        # This will be fixed when the client responds to the ICMP prohibited by filter message:
        # https://github.com/firezone/firezone/issues/10074
        push(
          socket,
          "reject_access",
          %{client_id: client_id, resource_id: resource_id}
        )

        {:noreply, assign(socket, cache: cache)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  # GATEWAYS

  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Gateways.Gateway{id: gateway_id}
         },
         %{
           assigns: %{gateway: %{id: gateway_id}}
         } = socket
       ) do
    {:stop, :shutdown, socket}
  end

  # RESOURCES

  # The gateway only handles filter changes for resources. Other addressability changes like address,
  # type, or ip_stack require sending reject_access to remove the resource state from the gateway.

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Resources.Resource{
             address: old_address,
             ip_stack: old_ip_stack,
             type: old_type
           },
           struct: %Resources.Resource{address: address, ip_stack: ip_stack, type: type, id: id}
         },
         socket
       )
       when old_address != address or
              old_ip_stack != ip_stack or
              old_type != type do
    for {client_id, resource_id} <- Cache.Gateway.all_pairs_for_resource(socket.assigns.cache, id) do
      # Send reject_access to the gateway to reset state. Clients will need to reauthorize the resource.
      push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})
    end

    # The cache will be updated by the flow deletion handler.
    {:noreply, socket}
  end

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Resources.Resource{filters: old_filters},
           struct: %Resources.Resource{filters: filters} = resource
         },
         socket
       )
       when old_filters != filters do
    # Send regardless of cache state - if the Gateway has no flows for this resource,
    # it will simply ignore the message.
    resource = Cache.Cacheable.to_cache(resource)

    case Resources.adapt_resource_for_version(resource, socket.assigns.gateway.last_seen_version) do
      nil ->
        {:noreply, socket}

      adapted_resource ->
        push(socket, "resource_updated", Views.Resource.render(adapted_resource))
        {:noreply, socket}
    end
  end

  defp handle_change(%Change{}, socket), do: {:noreply, socket}

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Accounts.Account

    def get_account_by_id!(id) do
      from(a in Account, where: a.id == ^id)
      |> Safe.unscoped()
      |> Safe.one!()
    end
  end
end
