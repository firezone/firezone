defmodule PortalAPI.Client.Channel do
  use PortalAPI, :channel
  alias PortalAPI.Client.Views

  alias Portal.{
    Cache,
    Channels,
    Changes.Change,
    PubSub,
    Gateway,
    Presence,
    Authentication
  }

  alias __MODULE__.Database
  require Logger
  require OpenTelemetry.Tracer

  # For time-based policy conditions, we need to determine whether we still have access
  # If not, we need to send resource_deleted so that if it's added back later, the client's
  # connlib state will be cleaned up so it can request a new connection.
  @recompute_authorized_resources_every :timer.minutes(1)

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def join("client", _payload, socket) do
    # If we crash, take the transport process down with us since connlib expects the WebSocket to close on error
    Process.link(socket.transport_pid)

    send(self(), :after_join)

    {:ok, socket}
  end

  @impl true
  # Called immediately after the client joins the channel
  def handle_info(:after_join, socket) do
    # Schedule reassessing allowed resources
    Process.send_after(
      self(),
      :recompute_authorized_resources,
      @recompute_authorized_resources_every
    )

    # Get initial list of authorized resources, hydrating the cache
    {:ok, resources, [], cache} =
      Cache.Client.recompute_connectable_resources(
        nil,
        socket.assigns.client,
        socket.assigns.session,
        socket.assigns.subject
      )

    # Initialize relays and subscribe to global relay presence
    {:ok, relays} = select_relays(socket)
    :ok = Presence.Relays.Global.subscribe()

    # Cache relay IDs and stamp secrets for tracking
    socket = cache_relays(socket, relays)

    # Track client's presence
    :ok = Presence.Clients.connect(socket.assigns.client, socket.assigns.subject.credential.id)

    # Register for targeted messages from gateway channels
    :ok = Channels.register_client(socket.assigns.client.id)
    :ok = PubSub.Changes.subscribe(socket.assigns.client.account_id)

    push(socket, "init", %{
      resources: Views.Resource.render_many(resources),
      relays:
        Views.Relay.render_many(
          relays,
          socket.assigns.session.public_key,
          socket.assigns.subject.expires_at
        ),
      interface:
        Views.Interface.render(%{
          socket.assigns.client
          | account: socket.assigns.subject.account
        })
    })

    {:noreply, assign(socket, cache: cache)}
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  def handle_info(%Change{lsn: lsn} = change, socket) do
    last_lsn = Map.get(socket.assigns, :last_lsn, 0)

    if lsn > last_lsn do
      case handle_change(change, socket) do
        {:noreply, socket} ->
          {:noreply, assign(socket, last_lsn: lsn)}

        result ->
          result
      end
    else
      # Change already processed; ignore to prevent replaying it
      {:noreply, socket}
    end
  end

  ####################################
  ##### Reacting to timed events #####
  ####################################

  # This is needed to keep the client's resource list up to date for time-based policy conditions
  # since we will not receive any change messages to react to when time-based policies expire.
  def handle_info(:recompute_authorized_resources, socket) do
    Process.send_after(
      self(),
      :recompute_authorized_resources,
      @recompute_authorized_resources_every
    )

    {:ok, added_resources, removed_ids, cache} =
      Cache.Client.recompute_connectable_resources(
        socket.assigns.cache,
        socket.assigns.client,
        socket.assigns.session,
        socket.assigns.subject
      )

    for resource_id <- removed_ids do
      push(socket, "resource_deleted", resource_id)
    end

    for resource <- added_resources do
      push(socket, "resource_created_or_updated", Views.Resource.render(resource))
    end

    {:noreply, assign(socket, cache: cache)}
  end

  ####################################
  #### Reacting to relay presence ####
  ####################################

  # Handle relay presence changes from global topic.
  # Instead of reacting immediately, we debounce by scheduling a delayed check.
  # This avoids spurious updates during transient relay disconnections.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:global_relays" <> _
        },
        socket
      ) do
    # Cancel any existing debounce timer to implement true debouncing
    # (only the last event in a burst triggers the check)
    if timer_ref = socket.assigns[:relay_presence_timer_ref] do
      Process.cancel_timer(timer_ref)
    end

    # Use a unique reference to identify this timer. When handling the message,
    # we check if it matches the current ref to prevent processing stale messages
    # that were already in the mailbox when the timer was cancelled.
    ref = make_ref()
    debounce_ms = Portal.Config.get_env(:portal, :relay_presence_debounce_ms, 1_000)
    timer_ref = Process.send_after(self(), {:check_relay_presence, ref}, debounce_ms)

    socket =
      socket
      |> assign(:relay_presence_timer_ref, timer_ref)
      |> assign(:relay_presence_ref, ref)

    {:noreply, socket}
  end

  # Debounced relay presence check - queries the CRDT state after the debounce period.
  # cached_relay_ids is a MapSet of relay IDs we've sent to the client.
  # Presence is keyed by relay ID.
  def handle_info({:check_relay_presence, ref}, socket) do
    # Only process if the ref matches the current active timer.
    # This prevents processing stale messages that were already in the mailbox
    # when Process.cancel_timer/1 was called.
    if ref != socket.assigns[:relay_presence_ref] do
      {:noreply, socket}
    else
      # Clear the timer references since we're processing now
      socket =
        socket
        |> assign(:relay_presence_timer_ref, nil)
        |> assign(:relay_presence_ref, nil)

      cached_relay_ids = socket.assigns[:cached_relay_ids] || MapSet.new()

      # Query presence ONCE - use this single snapshot for both determining
      # disconnected relays and selecting connected relays. This avoids a race
      # condition where CRDT state changes between queries during rapid
      # disconnect/reconnect cycles.
      {:ok, all_online_relays} = Presence.Relays.all_connected_relays()
      online_relay_ids = MapSet.new(all_online_relays, & &1.id)

      # Find which cached relays are now truly offline (ID no longer in presence)
      disconnected_ids =
        cached_relay_ids
        |> Enum.reject(&MapSet.member?(online_relay_ids, &1))
        |> Enum.to_list()

      # Send relays_presence if any cached relays are disconnected OR if we have fewer than 2 relays
      # and more are now available
      needs_update =
        disconnected_ids != [] or
          (MapSet.size(cached_relay_ids) < 2 and MapSet.size(online_relay_ids) > 0)

      if needs_update do
        # Select best relays from the SAME snapshot we used for disconnected_ids
        location = {
          socket.assigns.subject.context.remote_ip_location_lat,
          socket.assigns.subject.context.remote_ip_location_lon
        }

        relays = load_balance_relays(location, all_online_relays)
        socket = cache_relays(socket, relays)

        push(socket, "relays_presence", %{
          disconnected_ids: disconnected_ids,
          connected:
            Views.Relay.render_many(
              relays,
              socket.assigns.session.public_key,
              socket.assigns.subject.expires_at
            )
        })

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end
  end

  #############################################################
  ##### Forwarding replies from the gateway to the client #####
  #############################################################

  # This the list of ICE candidates gathered by the gateway and relayed to the client
  def handle_info({:ice_candidates, gateway_id, candidates}, socket) do
    # TODO: Add version gate to rename this message to `new_gateway_ice_candidates`
    # once client <> client is live.
    push(socket, "ice_candidates", %{
      gateway_id: gateway_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info({:invalidate_ice_candidates, gateway_id, candidates}, socket) do
    # TODO: Add version gate to rename this message to `invalidate_gateway_ice_candidates`
    # once client <> client is live.
    push(socket, "invalidate_ice_candidates", %{
      gateway_id: gateway_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info({:ice_candidates, client_id, candidates}, socket) do
    push(socket, "new_client_ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info({:invalidate_ice_candidates, client_id, candidates}, socket) do
    push(socket, "invalidate_client_ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  # DEPRECATED IN 1.4
  # This message is sent by the gateway when it is ready to accept the connection from the client
  def handle_info(
        {:connect, socket_ref, rid_bytes, gateway_public_key, payload},
        socket
      ) do
    reply(
      socket_ref,
      {:ok,
       %{
         resource_id: Ecto.UUID.load!(rid_bytes),
         persistent_keepalive: 25,
         gateway_public_key: gateway_public_key,
         gateway_payload: payload
       }}
    )

    {:noreply, socket}
  end

  def handle_info(
        {:connect, _socket_ref, rid_bytes, site_id, gateway_id, gateway_public_key, gateway_ipv4,
         gateway_ipv6, preshared_key, ice_credentials},
        socket
      ) do
    resource_id = Ecto.UUID.load!(rid_bytes)
    pending_flows = Map.get(socket.assigns, :pending_flows, %{})

    if Map.has_key?(pending_flows, resource_id) do
      reply_payload = %{
        resource_id: resource_id,
        preshared_key: preshared_key,
        client_ice_credentials: ice_credentials.client,
        # TODO: conditionally rename to site_id based on client version
        # apple: >= 1.5.11
        # headless: >= 1.5.6
        # android: >= 1.5.8
        # gui: >= 1.5.10
        # See https://github.com/firezone/firezone/commit/9d8b55212aea418264a272109776e795f5eda6ce
        gateway_group_id: site_id,
        gateway_id: gateway_id,
        gateway_public_key: gateway_public_key,
        gateway_ipv4: gateway_ipv4,
        gateway_ipv6: gateway_ipv6,
        gateway_ice_credentials: ice_credentials.gateway
      }

      push(socket, "flow_created", reply_payload)

      socket = cancel_pending_flow(socket, resource_id)
      {:noreply, socket}
    else
      # Flow already timed out — ignore late gateway response
      {:noreply, socket}
    end
  end

  def handle_info({:flow_creation_timeout, resource_id}, socket) do
    pending_flows = Map.get(socket.assigns, :pending_flows, %{})

    if Map.has_key?(pending_flows, resource_id) do
      push(socket, "flow_creation_failed", %{resource_id: resource_id, reason: :offline})
      {:noreply, assign(socket, :pending_flows, Map.delete(pending_flows, resource_id))}
    else
      {:noreply, socket}
    end
  end

  # Catch-all for messages we don't handle
  def handle_info(_message, socket), do: {:noreply, socket}

  ####################################
  ##### Client-initiated actions #####
  ####################################

  # This message is sent to the client to request a network flow with a gateway that can serve given resource.
  #
  # `connected_gateway_ids` is used to indicate that the client is already connected to some of the gateways,
  # so the gateway can be reused by multiplexing the connection.
  def handle_in(
        "create_flow",
        %{
          "resource_id" => resource_id,
          "connected_gateway_ids" => connected_gateway_ids
        },
        socket
      ) do
    with {:ok, resource, membership_id, policy_id, expires_at} <-
           Cache.Client.authorize_resource(
             socket.assigns.cache,
             socket.assigns.client,
             socket.assigns.session,
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateways} when gateways != [] <-
           Database.all_compatible_gateways_for_client_and_resource(
             socket.assigns.client_version,
             resource,
             socket.assigns.subject
           ) do
      location = {
        socket.assigns.subject.context.remote_ip_location_lat,
        socket.assigns.subject.context.remote_ip_location_lon
      }

      gateway = Gateway.load_balance_gateways(location, gateways, connected_gateway_ids)

      # TODO: Optimization
      # Move this to a Task.start that completes after broadcasting authorize_flow
      {:ok, policy_authorization} =
        create_policy_authorization(
          socket.assigns.client,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          socket.assigns.subject,
          expires_at
        )

      preshared_key =
        generate_preshared_key(socket.assigns.client, socket.assigns.session.public_key, gateway)

      ice_credentials =
        generate_ice_credentials(
          socket.assigns.session.public_key,
          socket.assigns.client,
          gateway
        )

      message =
        {:authorize_policy, {self(), socket_ref(socket)},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               socket.assigns.client,
               socket.assigns.session.public_key,
               preshared_key,
               socket.assigns.subject.context.user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(socket.assigns.subject),
           resource: PortalAPI.Gateway.Views.Resource.render(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}

      case Channels.send_to_gateway(gateway.id, message) do
        :ok ->
          timer_ref =
            Process.send_after(
              self(),
              {:flow_creation_timeout, resource_id},
              flow_creation_timeout()
            )

          pending_flows = Map.get(socket.assigns, :pending_flows, %{})
          socket = assign(socket, :pending_flows, Map.put(pending_flows, resource_id, timer_ref))
          {:noreply, socket}

        {:error, :not_found} ->
          push(socket, "flow_creation_failed", %{resource_id: resource_id, reason: :offline})
          {:noreply, socket}
      end
    else
      {:error, :not_found} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :not_found
        })

        {:noreply, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :forbidden,
          violated_properties: violated_properties
        })

        {:noreply, socket}

      {:ok, []} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :offline
        })

        {:noreply, socket}

      {:error, :version_mismatch} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :version_mismatch
        })

        {:noreply, socket}
    end
  end

  # This message is sent from a client to request access to another device.
  def handle_in(
        "request_device_access",
        %{
          "ipv4" => _ivp4
        },
        socket
      ) do
    # TODO: Connect to device.

    # push(socket, "client_device_access_authorized", %{
    #   client_id: ...,
    #   client_public_key: ...,
    #   client_ipv4: ...,
    #   client_ipv6: ...,
    #   preshared_key: ...,
    #   local_ice_credentials: ...,
    #   remote_ice_credentials: ...,
    #   ice_role: :controlling | :controlled,
    # })
    #
    # Or fail:
    #
    # push(socket, "client_device_access_denied", %{
    #   client_id: ...,
    #   client_ipv4: ...,
    #   client_ipv6: ...,
    #   reason: :not_found | :forbidden etc (same as for gateway)
    # })

    {:noreply, socket}
  end

  # DEPRECATED IN 1.4
  # The client sends it's message to list relays and select a gateway whenever it wants
  # to connect to a resource.
  #
  # Client can send `connected_gateway_ids` to indicate that it is already connected to
  # some of the gateways and can multiplex the connections.
  @impl true
  def handle_in("prepare_connection", %{"resource_id" => resource_id} = attrs, socket) do
    connected_gateway_ids = Map.get(attrs, "connected_gateway_ids", [])

    # TODO: Optimization
    # Gateway selection and flow authorization shouldn't need to hit the DB
    with {:ok, resource, _membership_id, _policy_id, _expires_at} <-
           Cache.Client.authorize_resource(
             socket.assigns.cache,
             socket.assigns.client,
             socket.assigns.session,
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateways} when gateways != [] <-
           Database.all_compatible_gateways_for_client_and_resource(
             socket.assigns.client_version,
             resource,
             socket.assigns.subject
           ) do
      location = {
        socket.assigns.subject.context.remote_ip_location_lat,
        socket.assigns.subject.context.remote_ip_location_lon
      }

      gateway = Gateway.load_balance_gateways(location, gateways, connected_gateway_ids)

      reply =
        {:ok,
         %{
           resource_id: resource_id,
           site_id: gateway.site_id,
           gateway_id: gateway.id,
           gateway_remote_ip: gateway.last_seen_remote_ip
         }}

      {:reply, reply, socket}
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:ok, []} ->
        {:reply, {:error, %{reason: :offline}}, socket}

      {:error, :version_mismatch} ->
        {:reply, {:error, %{reason: :version_mismatch}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}
    end
  end

  # DEPRECATED IN 1.4
  # This message is sent by the client when it already has connection to a gateway,
  # but wants to multiplex the connection to access a new resource
  def handle_in(
        "reuse_connection",
        %{
          "gateway_id" => gateway_id,
          "resource_id" => resource_id,
          "payload" => payload
        },
        socket
      ) do
    with {:ok, resource, membership_id, policy_id, expires_at} <-
           Cache.Client.authorize_resource(
             socket.assigns.cache,
             socket.assigns.client,
             socket.assigns.session,
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateway} <-
           Database.fetch_gateway_by_id(gateway_id, socket.assigns.subject)
           |> then(fn
             {:ok, gw} ->
               {:ok, Presence.Gateways.preload_gateways_presence([gw]) |> List.first()}

             error ->
               error
           end),
         true <- resource.site != nil and resource.site.id == Ecto.UUID.dump!(gateway.site_id),
         true <- gateway.online? do
      # TODO: Optimization
      {:ok, policy_authorization} =
        create_policy_authorization(
          socket.assigns.client,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          socket.assigns.subject,
          expires_at
        )

      case Channels.send_to_gateway(
             gateway.id,
             {:allow_access, {self(), socket_ref(socket)},
              %{
                client_id: socket.assigns.client.id,
                client_ipv4: socket.assigns.client.ipv4_address.address,
                client_ipv6: socket.assigns.client.ipv6_address.address,
                resource: resource,
                policy_authorization_id: policy_authorization.id,
                authorization_expires_at: expires_at,
                client_payload: payload
              }}
           ) do
        :ok ->
          {:noreply, socket}

        {:error, :not_found} ->
          {:reply, {:error, %{reason: :offline}}, socket}
      end
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}

      false ->
        {:reply, {:error, %{reason: :offline}}, socket}
    end
  end

  # DEPRECATED IN 1.4
  # This message is sent by the client when it wants to connect to a new gateway
  # to access a resource
  def handle_in(
        "request_connection",
        %{
          "gateway_id" => gateway_id,
          "resource_id" => resource_id,
          "client_payload" => client_payload,
          "client_preshared_key" => preshared_key
        },
        socket
      ) do
    # Flow authorization can happen out-of-band since we just authorized the resource above
    with {:ok, resource, membership_id, policy_id, expires_at} <-
           Cache.Client.authorize_resource(
             socket.assigns.cache,
             socket.assigns.client,
             socket.assigns.session,
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateway} <-
           Database.fetch_gateway_by_id(gateway_id, socket.assigns.subject)
           |> then(fn
             {:ok, gw} ->
               {:ok, Presence.Gateways.preload_gateways_presence([gw]) |> List.first()}

             error ->
               error
           end),
         true <- resource.site != nil and resource.site.id == Ecto.UUID.dump!(gateway.site_id),
         true <- gateway.online? do
      # TODO: Optimization
      {:ok, policy_authorization} =
        create_policy_authorization(
          socket.assigns.client,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          socket.assigns.subject,
          expires_at
        )

      case Channels.send_to_gateway(
             gateway.id,
             {:request_connection, {self(), socket_ref(socket)},
              %{
                client:
                  PortalAPI.Gateway.Views.Client.render_legacy(
                    socket.assigns.client,
                    socket.assigns.session.public_key,
                    client_payload,
                    preshared_key
                  ),
                resource: resource,
                policy_authorization_id: policy_authorization.id,
                authorization_expires_at: expires_at
              }}
           ) do
        :ok ->
          {:noreply, socket}

        {:error, :not_found} ->
          {:reply, {:error, %{reason: :offline}}, socket}
      end
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}

      false ->
        {:reply, {:error, %{reason: :offline}}, socket}
    end
  end

  # The client pushes it's ICE candidates list and the list of gateways that need to receive it
  def handle_in(
        "broadcast_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    Enum.each(gateway_ids, fn gateway_id ->
      Channels.send_to_gateway(
        gateway_id,
        {:ice_candidates, socket.assigns.client.id, candidates}
      )
    end)

    {:noreply, socket}
  end

  def handle_in(
        "broadcast_invalidated_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    Enum.each(gateway_ids, fn gateway_id ->
      Channels.send_to_gateway(
        gateway_id,
        {:invalidate_ice_candidates, socket.assigns.client.id, candidates}
      )
    end)

    {:noreply, socket}
  end

  # The client pushes it's ICE candidates list and the gateways that need to receive it
  def handle_in(
        "new_gateway_ice_candidates",
        %{"candidates" => candidates, "gateway_id" => gateway_id},
        socket
      ) do
    :ok =
      Channels.send_to_gateway(
        gateway_id,
        {:ice_candidates, socket.assigns.client.id, candidates}
      )

    {:noreply, socket}
  end

  def handle_in(
        "invalidate_gateway_ice_candidates",
        %{"candidates" => candidates, "gateway_id" => gateway_id},
        socket
      ) do
    :ok =
      Channels.send_to_gateway(
        gateway_id,
        {:invalidate_ice_candidates, socket.assigns.client.id, candidates}
      )

    {:noreply, socket}
  end

  # The client pushes it's ICE candidates list and the gateways that need to receive it
  def handle_in(
        "new_client_ice_candidates",
        %{"candidates" => candidates, "client_id" => client_id},
        socket
      ) do
    :ok =
      Channels.send_to_client(
        client_id,
        {:ice_candidates, socket.assigns.client.id, candidates}
      )

    {:noreply, socket}
  end

  def handle_in(
        "invalidate_client_ice_candidates",
        %{"candidates" => candidates, "client_id" => client_id},
        socket
      ) do
    :ok =
      Channels.send_to_client(
        client_id,
        {:invalidate_ice_candidates, socket.assigns.client.id, candidates}
      )

    {:noreply, socket}
  end

  # Catch-all for unknown messages
  def handle_in(message, payload, socket) do
    Logger.error("Unknown client message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  defp select_relays(socket, except_ids \\ []) do
    {:ok, relays} = Presence.Relays.all_connected_relays(except_ids)

    location = {
      socket.assigns.subject.context.remote_ip_location_lat,
      socket.assigns.subject.context.remote_ip_location_lon
    }

    relays = load_balance_relays(location, relays)

    {:ok, relays}
  end

  defp cache_relays(socket, relays) do
    cached_relay_ids = MapSet.new(relays, fn relay -> relay.id end)
    assign(socket, :cached_relay_ids, cached_relay_ids)
  end

  defp generate_preshared_key(client, client_public_key, gateway) do
    Portal.Crypto.psk(client, client_public_key, gateway)
  end

  # Ice credentials must stay the same for all connections between client and gateway as long as they
  # do not loose their state, so we can leverage public_key which is reset on each restart of the client
  # or gateway.
  defp generate_ice_credentials(client_public_key, client, gateway) do
    ice_credential_seed =
      [
        client.id,
        client_public_key,
        gateway.id,
        gateway.public_key
      ]
      |> Enum.join(":")

    ice_credential_seed_hash =
      :crypto.hash(:sha256, ice_credential_seed)
      |> Base.encode32(case: :lower, padding: false)

    [
      {:client_username, client_username},
      {:client_password, client_password},
      {:gateway_username, gateway_username},
      {:gateway_password, gateway_password}
    ] =
      Enum.map(
        [
          client_username: 0..3,
          client_password: 4..25,
          gateway_username: 26..29,
          gateway_password: 30..52
        ],
        fn {key, range} ->
          {key, String.slice(ice_credential_seed_hash, range)}
        end
      )

    %{
      client: %{username: client_username, password: client_password},
      gateway: %{username: gateway_username, password: gateway_password}
    }
  end

  ##########################################
  #### Handling changes from the domain ####
  ##########################################

  # ACCOUNTS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Account{} = old_account,
           struct: %Portal.Account{} = account
         },
         socket
       ) do
    # Update our subject's account
    subject = %{socket.assigns.subject | account: account}
    socket = assign(socket, subject: subject)

    if old_account.config != account.config do
      client = %{socket.assigns.client | account: account}
      payload = %{interface: Views.Interface.render(client)}
      :ok = push(socket, "config_changed", payload)
    end

    {:noreply, socket}
  end

  # MEMBERSHIPS

  defp handle_change(
         %Change{op: :insert, struct: %Portal.Membership{actor_id: actor_id}},
         %{assigns: %{client: %{actor_id: id}}} = socket
       )
       when id == actor_id do
    Cache.Client.add_membership(
      socket.assigns.cache,
      socket.assigns.client,
      socket.assigns.session,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Portal.Membership{actor_id: actor_id} = membership
         },
         %{assigns: %{client: %{actor_id: id}}} = socket
       )
       when id == actor_id do
    Cache.Client.delete_membership(
      socket.assigns.cache,
      membership,
      socket.assigns.client,
      socket.assigns.session,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  # CLIENTS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Client{} = old_client,
           struct: %Portal.Client{id: client_id} = client
         },
         %{assigns: %{client: %{id: id} = current_client}} = socket
       )
       when id == client_id do
    # Update socket with the new client state, preserving loaded associations
    updated_client = %{
      client
      | account: current_client.account,
        actor: current_client.actor,
        ipv4_address: current_client.ipv4_address,
        ipv6_address: current_client.ipv6_address
    }

    socket = assign(socket, :client, updated_client)

    # Changes in client verification can affect the list of allowed resources
    if old_client.verified_at != client.verified_at do
      Cache.Client.recompute_connectable_resources(
        socket.assigns.cache,
        socket.assigns.client,
        socket.assigns.session,
        socket.assigns.subject
      )
      |> push_resource_updates(socket)
    else
      {:noreply, socket}
    end
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.Client{id: id}},
         %{assigns: %{client: %{id: client_id}}} = socket
       )
       when id == client_id do
    # Deleting a client won't necessary delete its tokens in the case of a headless client.
    # So we explicitly handle the deleted client here by forcing it to reconnect.
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
    Cache.Client.update_resources_with_site_name(
      socket.assigns.cache,
      site,
      socket.assigns.client,
      socket.assigns.session,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  # POLICIES

  defp handle_change(
         %Change{op: :insert, struct: %Portal.Policy{} = policy},
         socket
       ) do
    Cache.Client.add_policy(
      socket.assigns.cache,
      policy,
      socket.assigns.client,
      socket.assigns.session,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Policy{
             resource_id: old_resource_id,
             group_id: old_group_id,
             conditions: old_conditions
           },
           struct: %Portal.Policy{
             resource_id: resource_id,
             group_id: group_id,
             conditions: conditions,
             disabled_at: disabled_at
           }
         } = change,
         socket
       )
       when old_resource_id != resource_id or old_group_id != group_id or
              old_conditions != conditions do
    # TODO: Optimization
    # Breaking update - process this as a delete and then create to make our lives easier.
    # We could be smarter here and process the individual side effects more cleverly to avoid
    # sending resource_deleted and resource_created_or_updated if the policy is not actually changing
    # the client's connectable_resources.
    {:noreply, socket} = handle_change(%{change | op: :delete}, socket)

    # DO NOT re-add disabled policies
    if is_nil(disabled_at) do
      handle_change(%{change | op: :insert}, socket)
    else
      {:noreply, socket}
    end
  end

  # Other update, i.e. description - just update our state
  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Policy{},
           struct: %Portal.Policy{} = policy
         },
         socket
       ) do
    Cache.Client.update_policy(socket.assigns.cache, policy)
    |> push_resource_updates(socket)
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.Policy{} = policy},
         socket
       ) do
    Cache.Client.delete_policy(
      socket.assigns.cache,
      policy,
      socket.assigns.client,
      socket.assigns.session,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  # RESOURCES

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Resource{},
           struct: %Portal.Resource{} = resource
         },
         socket
       ) do
    Cache.Client.update_resource(
      socket.assigns.cache,
      resource,
      socket.assigns.client,
      socket.assigns.session,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  defp handle_change(%Change{}, socket), do: {:noreply, socket}

  defp push_resource_updates({:ok, added_resources, removed_ids, cache}, socket) do
    # Currently, connlib doesn't handle resources changing sites, so we need to delete then create.
    # We handle that scenario by sending resource_deleted then resource_created_or_updated, so it's
    # important that deletions are processed first here.
    # See https://github.com/firezone/firezone/issues/9881
    for resource_id <- removed_ids do
      push(socket, "resource_deleted", resource_id)
    end

    for resource <- added_resources do
      push(socket, "resource_created_or_updated", Views.Resource.render(resource))
    end

    {:noreply, assign(socket, cache: cache)}
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, Gateway}

    def fetch_gateway_by_id(id, subject) do
      result =
        from(g in Gateway, as: :gateways)
        |> where([gateways: g], g.id == ^id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        gateway -> {:ok, gateway}
      end
    end

    def all_compatible_gateways_for_client_and_resource(
          client_version,
          resource,
          subject
        ) do
      resource_site_id = site_id_from_resource(resource)

      connected_gateway_ids =
        Presence.Gateways.Account.list(subject.account.id)
        |> Map.keys()

      online_gateways =
        from(g in Gateway, as: :gateways)
        |> where([gateways: g], g.id in ^connected_gateway_ids and g.site_id == ^resource_site_id)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> case do
          {:error, :unauthorized} -> []
          gateways -> gateways
        end

      compatible_gateways =
        filter_compatible_gateways(online_gateways, resource, client_version)

      cond do
        compatible_gateways != [] ->
          {:ok, compatible_gateways}

        online_gateways != [] ->
          # Gateways are online but all were filtered out due to version incompatibility
          {:error, :version_mismatch}

        true ->
          # No gateways online at all
          {:ok, []}
      end
    end

    # Filters gateways by the resource type, gateway version, and client version.
    defp filter_compatible_gateways(gateways, _resource, nil), do: gateways

    defp filter_compatible_gateways(gateways, resource, client_version) do
      case Version.parse(client_version) do
        {:ok, version} ->
          gateways
          |> Enum.filter(fn gateway ->
            case Version.parse(gateway.last_seen_version) do
              {:ok, gateway_version} ->
                Version.match?(gateway_version, ">= #{version.major}.#{version.minor - 1}.0") and
                  Version.match?(gateway_version, "< #{version.major}.#{version.minor + 2}.0") and
                  not is_nil(
                    Portal.Resource.adapt_resource_for_version(
                      resource,
                      gateway.last_seen_version
                    )
                  )

              _ ->
                false
            end
          end)

        :error ->
          []
      end
    end

    defp site_id_from_resource(%Portal.Cache.Cacheable.Resource{site: nil}), do: nil

    defp site_id_from_resource(%Portal.Cache.Cacheable.Resource{site: site}) do
      Ecto.UUID.load!(site.id)
    end
  end

  defp load_balance_relays({lat, lon}, relays) when is_nil(lat) or is_nil(lon) do
    relays
    |> Enum.shuffle()
    |> Enum.take(2)
  end

  defp load_balance_relays({lat, lon}, relays) do
    relays
    |> Enum.map(fn relay ->
      case {relay.lat, relay.lon} do
        {nil, _} -> {nil, relay}
        {_, nil} -> {nil, relay}
        {relay_lat, relay_lon} -> {Portal.Geo.distance({lat, lon}, {relay_lat, relay_lon}), relay}
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), &nils_last/2)
    |> Enum.take(2)
    |> Enum.map(&elem(&1, 1))
  end

  defp nils_last(nil, _), do: false
  defp nils_last(_, nil), do: true
  defp nils_last(a, b), do: a <= b

  # Inline functions from Portal.PolicyAuthorizations

  defp create_policy_authorization(
         %Portal.Client{
           id: client_id,
           account_id: account_id,
           actor_id: actor_id
         },
         %Portal.Gateway{
           id: gateway_id,
           last_seen_remote_ip: gateway_remote_ip,
           account_id: account_id
         },
         resource_id,
         policy_id,
         membership_id,
         %Authentication.Subject{
           account: %{id: account_id},
           actor: %{id: actor_id},
           credential: %{id: token_id},
           context: %Authentication.Context{
             remote_ip: client_remote_ip,
             user_agent: client_user_agent
           }
         } = subject,
         expires_at
       ) do
    changeset =
      create_policy_authorization_changeset(%{
        token_id: token_id,
        policy_id: policy_id,
        client_id: client_id,
        gateway_id: gateway_id,
        resource_id: resource_id,
        membership_id: membership_id,
        account_id: account_id,
        client_remote_ip: client_remote_ip,
        client_user_agent: client_user_agent,
        gateway_remote_ip: gateway_remote_ip,
        expires_at: expires_at
      })

    Portal.Safe.scoped(changeset, subject)
    |> Portal.Safe.insert()
  end

  defp create_policy_authorization_changeset(attrs) do
    import Ecto.Changeset

    fields = ~w[token_id policy_id client_id gateway_id resource_id membership_id
                account_id
                expires_at
                client_remote_ip client_user_agent
                gateway_remote_ip]a

    %Portal.PolicyAuthorization{}
    |> cast(attrs, fields)
    |> validate_required(fields -- [:membership_id])
    |> Portal.PolicyAuthorization.changeset()
  end

  defp cancel_pending_flow(socket, resource_id) do
    pending_flows = Map.get(socket.assigns, :pending_flows, %{})

    case Map.pop(pending_flows, resource_id) do
      {nil, _} ->
        socket

      {timer_ref, remaining} ->
        Process.cancel_timer(timer_ref)
        assign(socket, :pending_flows, remaining)
    end
  end

  defp flow_creation_timeout do
    Portal.Config.get_env(:portal, :flow_creation_timeout_ms, :timer.seconds(15))
  end
end
