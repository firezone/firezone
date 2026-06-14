defmodule PortalAPI.Client.Channel do
  use PortalAPI, :channel
  alias PortalAPI.Client.Views

  alias Portal.{
    Cache,
    Device,
    PG,
    Changes.Change,
    Features,
    PubSub,
    Presence,
    Authentication
  }

  alias Portal.Repo.Batch
  alias __MODULE__.Database
  require Logger

  # For time-based policy conditions, we need to determine whether we still have access
  # If not, we need to send resource_deleted so that if it's added back later, the client's
  # connlib state will be cleaned up so it can request a new connection.
  @recompute_authorized_resources_every :timer.minutes(1)

  # The interval at which the inbound policy_authorizations cache is pruned.
  @prune_authorizations_cache_every :timer.minutes(1)

  @session_durability_timeout :timer.seconds(15)

  @doc false
  def policy_authorization_queue_opts do
    [
      name: :policy_authorization_queue,
      flush_interval: :timer.seconds(1),
      flush_threshold: 10_000,
      label: "policy authorization",
      on_flush: &flush_policy_authorizations/1
    ]
  end

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def join("client", _payload, socket) do
    send(self(), :after_join)

    {:ok, socket}
  end

  # On an abnormal exit, drain the whole WebSocket instead of just letting the
  # channel die. connlib ignores `phx_error` and would keep the transport alive,
  # re-joining reactively and reusing the transport-scoped session id (which
  # collides with the row already persisted). Draining forces a full reconnect
  # that re-runs `Socket.connect/3` and mints a fresh id, keeping transport:session
  # 1:1. Graceful stops already send `phx_close`, so we only intervene here.
  @impl true
  def terminate(reason, socket) do
    if abnormal_exit?(reason) do
      send(socket.transport_pid, :socket_drain)
    end

    :ok
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

    Process.send_after(
      self(),
      :prune_authorizations_cache,
      @prune_authorizations_cache_every
    )

    schedule_session_expiry(socket.assigns.subject.expires_at)

    # Get initial list of authorized resources, hydrating the cache
    {:ok, resources, [], cache} =
      Cache.Client.recompute_connectable_resources(
        nil,
        socket.assigns.client,
        socket.assigns.session,
        socket.assigns.subject
      )

    # Hydrate inbound policy_authorizations cache so the channel can react to filter
    # changes and policy_authorization deletions for resources another client has been
    # authorized to access via this one.
    authorizations_cache = Cache.Client.Authorizations.hydrate(socket.assigns.client)

    # Initialize relays and subscribe to global relay presence
    {:ok, relays} = select_relays(socket)
    :ok = Presence.Relays.Global.subscribe()

    socket =
      socket
      # Cache relay IDs and stamp secrets for tracking
      |> cache_relays(relays)
      |> assign(
        cache: cache,
        authorizations_cache: authorizations_cache,
        pending_flows: %{}
      )
      # Track client's presence and monitor tracker shard processes for crash recovery
      |> track_presence()

    :ok = PubSub.Changes.subscribe(socket.assigns.client.account_id)

    {:noreply, socket} = register(socket)

    init(socket, resources, relays)

    {:noreply, socket}
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
      push(
        socket,
        "resource_created_or_updated",
        Views.Resource.render(resource, socket.assigns.session)
      )
    end

    {:noreply, assign(socket, cache: cache)}
  end

  def handle_info(:prune_authorizations_cache, socket) do
    Process.send_after(
      self(),
      :prune_authorizations_cache,
      @prune_authorizations_cache_every
    )

    {:noreply,
     assign(
       socket,
       authorizations_cache: Cache.Client.Authorizations.prune(socket.assigns.authorizations_cache)
     )}
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
    push(socket, "ice_candidates", %{
      gateway_id: gateway_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info({:invalidate_ice_candidates, gateway_id, candidates}, socket) do
    push(socket, "invalidate_ice_candidates", %{
      gateway_id: gateway_id,
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

    case Map.pop(socket.assigns.pending_flows, resource_id) do
      {nil, _} ->
        # Flow already timed out — ignore late gateway response
        {:noreply, socket}

      {{timer_ref, policy_id}, remaining} ->
        Process.cancel_timer(timer_ref)

        reply_payload =
          %{
            resource_id: resource_id,
            preshared_key: preshared_key,
            client_ice_credentials: ice_credentials.initiator,
            gateway_id: gateway_id,
            gateway_public_key: gateway_public_key,
            gateway_ipv4: gateway_ipv4,
            gateway_ipv6: gateway_ipv6,
            gateway_ice_credentials: ice_credentials.receiver,
            policy_id: policy_id
          }
          |> put_site_id(site_id, socket.assigns.session)

        push(socket, "flow_created", reply_payload)
        {:noreply, assign(socket, :pending_flows, remaining)}
    end
  end

  def handle_info({:flow_creation_timeout, key}, socket) do
    case Map.pop(socket.assigns.pending_flows, key) do
      {nil, _} ->
        {:noreply, socket}

      # Client-to-client: the target's channel never acked that it pushed the
      # authorization to its data plane (e.g. it disconnected in the window).
      {%{deny_payload: deny_payload}, remaining} ->
        push(socket, "client_device_access_denied", deny_payload)
        {:noreply, assign(socket, :pending_flows, remaining)}

      {_timer_ref, remaining} ->
        push(socket, "flow_creation_failed", %{resource_id: key, reason: :offline})
        {:noreply, assign(socket, :pending_flows, remaining)}
    end
  end

  # Client-to-client: the target's channel confirmed it pushed the
  # authorization onto the target's websocket. Only now is it safe to release
  # the initiator, because the target's data plane is guaranteed to receive
  # (and process) the authorization before any relayed ICE candidate, which
  # travels the same socket behind it. See `deliver_pool_target_authorized/8`.
  def handle_info({:device_access_acked, ref}, socket) do
    case Map.pop(socket.assigns.pending_flows, ref) do
      {nil, _} ->
        {:noreply, socket}

      {%{timer_ref: timer_ref, initiator_payload: initiator_payload}, remaining} ->
        Process.cancel_timer(timer_ref)
        push(socket, "client_device_access_authorized", initiator_payload)
        {:noreply, assign(socket, :pending_flows, remaining)}
    end
  end

  def handle_info({:client_device_access_authorized, {ack_to, ref}, payload}, socket) do
    {policy_authorization_id, payload} = Map.pop(payload, :policy_authorization_id)
    {authorization_expires_at, payload} = Map.pop(payload, :authorization_expires_at)
    {policy_authorization, payload} = Map.pop(payload, :policy_authorization)

    authorizations_cache =
      maybe_put_authorization(
        socket.assigns.authorizations_cache,
        payload[:client_id],
        payload[:resource],
        policy_authorization_id,
        payload[:policy_id],
        authorization_expires_at
      )

    payload =
      if match?(%DateTime{}, authorization_expires_at) do
        Map.put(payload, :expires_at, DateTime.to_unix(authorization_expires_at, :second))
      else
        payload
      end

    push(socket, "client_device_access_authorized", payload)

    # Ack back to the initiator's channel that the authorization is on this
    # target's websocket. The initiator is released only after this, so the
    # initiator's ICE candidates (which traverse the same socket) can never
    # overtake the authorization at the target's data plane.
    send(ack_to, {:device_access_acked, ref})

    cache = Cache.Client.track_authorized_device_ipv4(socket.assigns.cache, payload.client_ipv4)

    socket =
      socket
      |> assign(cache: cache, authorizations_cache: authorizations_cache)
      |> maybe_arm_authz_durability_timer(policy_authorization)

    {:noreply, socket}
  end

  def handle_info({:client_ice_candidates, client_id, candidates}, socket) do
    push(socket, "client_ice_candidates", %{client_id: client_id, candidates: candidates})
    {:noreply, socket}
  end

  def handle_info({:invalidate_client_ice_candidates, client_id, candidates}, socket) do
    push(socket, "invalidate_client_ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  # Delivered to the receiver (peer client, in the client-to-client case) via
  # `Portal.PG` when a policy_authorization fails to persist after the receiver
  # was already told it could accept the connection. Mirrors the gateway's
  # reject_access handler: drop the cached authorization and push `reject_access`
  # via the same eviction path used for CDC deletes.
  def handle_info({:reject_access, %Portal.PolicyAuthorization{} = policy_authorization}, socket) do
    socket = cancel_authz_durability_timer(socket, policy_authorization.id)
    revoke_policy_authorization(socket, policy_authorization)
  end

  # Queue confirms a c2c policy_authorization was durably persisted; cancel
  # the authz durability timer so the timer doesn't fire and revoke.
  def handle_info({:confirm_authz_durability, authz_id}, socket) do
    {:noreply, cancel_authz_durability_timer(socket, authz_id)}
  end

  def handle_info({:confirm_session_durability, session_id}, socket) do
    {:noreply, cancel_session_durability_timer(socket, session_id)}
  end

  # Authz durability timer fired — no confirm/reject arrived in time. Fail-closed.
  # See gateway channel's equivalent handler for the rationale on the
  # generation check.
  def handle_info({:authz_durability_timeout, %Portal.PolicyAuthorization{} = pa, generation}, socket) do
    case Map.get(socket.assigns[:authz_durability] || %{}, pa.id) do
      {^generation, _ref} ->
        Logger.warning(
          "Authz durability timeout firing for c2c authz #{inspect(pa.id)} — queue never confirmed durability"
        )

        socket = cancel_authz_durability_timer(socket, pa.id)
        revoke_policy_authorization(socket, pa)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:session_durability_timeout, session_id, generation}, socket) do
    case socket.assigns[:session_durability] do
      {^session_id, ^generation, _timer_ref} ->
        Logger.warning(
          "Client session #{inspect(session_id)} was not confirmed durable; disconnecting"
        )

        # Avoid sending "token_expired" since that will tear down connlib
        # state in the client. Instead, the client must reconnect.
        {:stop, :shutdown, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(:disconnect, socket) do
    # Important: We push disconnect before closing the socket to prevent the client from
    # attempting to immediately reconnect
    push(socket, "disconnect", %{reason: "token_expired"})
    {:stop, :shutdown, socket}
  end

  # A monitored process crashed — determine which subsystem it belongs to and recover.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    cond do
      pid == socket.assigns[:pg_scope_pid] ->
        register(socket)

      Enum.any?(socket.assigns[:presence_monitors] || [], fn {p, _ref} -> p == pid end) ->
        {:noreply, track_presence(socket)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(:register, socket) do
    register(socket)
  end

  def handle_info(:track_presence, socket) do
    {:noreply, track_presence(socket)}
  end

  # Catch-all for messages we don't handle
  def handle_info(_message, socket), do: {:noreply, socket}

  defp flush_policy_authorizations(entries) do
    {inserted, failed} =
      Batch.insert_all(Portal.PolicyAuthorization, entries,
        label: "policy authorization",
        fk_partitions: %{
          "policy_authorizations_account_id_fkey" => {:simple, :account_id, Portal.Account},
          "policy_authorizations_policy_id_fkey" => {:composite, :policy_id, Portal.Policy},
          "policy_authorizations_resource_id_fkey" =>
            {:composite, :resource_id, Portal.Resource},
          "policy_authorizations_token_id_fkey" =>
            {:composite, :token_id, Portal.ClientToken},
          "policy_authorizations_membership_id_fkey" =>
            {:composite_optional, :membership_id, Portal.Membership},
          "policy_authorizations_initiating_device_id_fkey" =>
            {:composite, :initiating_device_id, Portal.Device},
          "policy_authorizations_receiving_device_id_fkey" =>
            {:composite, :receiving_device_id, Portal.Device}
        }
      )

    dispatch_failed_policy_authorizations(failed)
    dispatch_confirmed_policy_authorizations(entries, failed)

    if failed != [] do
      Logger.warning(
        "Skipped #{length(failed)} policy authorization entries during flush due to missing references"
      )
    end

    inserted
  end

  defp dispatch_failed_policy_authorizations(failed) do
    for {attrs, _metadata} <- failed do
      dispatch_queue_callback("policy authorization", :on_failed, attrs, fn ->
        policy_authorization = struct(Portal.PolicyAuthorization, attrs)

        PG.deliver(
          attrs.receiving_device_id,
          {:reject_access, policy_authorization}
        )
      end)
    end
  end

  defp dispatch_confirmed_policy_authorizations(entries, failed) do
    failed_ids = MapSet.new(failed, fn {attrs, _metadata} -> attrs[:id] end)

    for {attrs, _metadata} <- entries, not MapSet.member?(failed_ids, attrs[:id]) do
      dispatch_queue_callback("policy authorization", :on_confirmed, attrs, fn ->
        PG.deliver(
          attrs.receiving_device_id,
          {:confirm_authz_durability, attrs.id}
        )
      end)
    end
  end

  defp dispatch_queue_callback(label, callback, attrs, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error(
        "Queue #{label} #{callback} crashed for entry #{inspect(attrs[:id])}: " <>
          Exception.message(error)
      )
  catch
    kind, reason ->
      Logger.error(
        "Queue #{label} #{callback} threw #{kind} for entry #{inspect(attrs[:id])}: " <>
          inspect(reason)
      )
  end

  defp put_site_id(payload, site_id, client_session) do
    key =
      if Portal.Version.client_supports_sites_payload?(client_session) do
        :site_id
      else
        :gateway_group_id
      end

    Map.put(payload, key, site_id)
  end

  ####################################
  ##### Client-initiated actions #####
  ####################################

  # This message is sent to the client to request a network flow with a gateway (or, for
  # static_device_pool resources, a peer client) that can serve the given resource.
  #
  # For gateway-backed resources, `connected_gateway_ids` indicates that the client is already
  # connected to some of the gateways, so the gateway can be reused by multiplexing the connection.
  #
  # For static_device_pool resources, the payload also carries `ipv4` or `ipv6` of the target
  # member device.
  def handle_in(
        "create_flow",
        %{"resource_id" => resource_id} = payload,
        socket
      ) do
    case Cache.Client.authorize_resource(
           socket.assigns.cache,
           socket.assigns.client,
           socket.assigns.session,
           resource_id,
           socket.assigns.subject
         ) do
      {:ok, %Cache.Cacheable.Resource{type: type} = resource, membership_id, policy_id,
       expires_at}
      when type in [:static_device_pool, :dynamic_device_pool] ->
        handle_create_pool_flow(
          resource_id,
          resource,
          membership_id,
          policy_id,
          expires_at,
          payload,
          socket
        )

      {:ok, resource, membership_id, policy_id, expires_at} ->
        connected_gateway_ids = Map.get(payload, "connected_gateway_ids", [])

        handle_create_gateway_flow(
          resource_id,
          resource,
          membership_id,
          policy_id,
          expires_at,
          connected_gateway_ids,
          socket
        )

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
    end
  end

  # Connlib intercepts DNS queries that match a registered dynamic_device_pool pattern
  # (e.g. `*.devices.example.com`) and asks the portal to resolve the FQDN to a tunnel
  # IP. We answer by looking the device up by hostname (case-insensitive) within the
  # client's account, then verifying the device's hostname still matches the pool's
  # pattern as defense in depth.
  def handle_in(
        "resolve_device_pool_domain",
        %{"resource_id" => resource_id, "domain" => domain},
        socket
      )
      when is_binary(resource_id) and is_binary(domain) do
    with {:ok, %Cache.Cacheable.Resource{type: :dynamic_device_pool, address: pattern}} <-
           fetch_connectable_dynamic_pool(socket.assigns.cache, resource_id),
         {:ok, %Portal.Device{} = device} <-
           Database.get_device_by_hostname(domain, socket.assigns.subject),
         true <- Portal.Resource.matches_dns_pattern?(pattern, device.hostname) do
      push(socket, "device_pool_domain_resolved", %{
        resource_id: resource_id,
        domain: domain,
        ipv4: %Postgrex.INET{address: device.ipv4.address, netmask: 32},
        ipv6: %Postgrex.INET{address: device.ipv6.address, netmask: 128}
      })
    else
      _ ->
        push(socket, "device_pool_domain_resolution_failed", %{
          resource_id: resource_id,
          domain: domain,
          reason: :not_found
        })
    end

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
             socket.assigns.subject.account.id
           ) do
      location = {
        socket.assigns.subject.context.remote_ip_location_lat,
        socket.assigns.subject.context.remote_ip_location_lon
      }

      gateway = Device.load_balance_gateways(location, gateways, connected_gateway_ids)

      reply =
        {:ok,
         %{
           resource_id: resource_id,
           site_id: gateway.site_id,
           gateway_id: gateway.id,
           gateway_remote_ip: gateway.latest_session && gateway.latest_session.remote_ip
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
           Presence.Gateways.fetch_gateway(socket.assigns.subject.account.id, gateway_id),
         true <- resource.site != nil and resource.site.id == Ecto.UUID.dump!(gateway.site_id) do
      policy_authorization_id = Ecto.UUID.generate()

      attrs =
        policy_authorization_attrs(
          policy_authorization_id,
          socket.assigns.client,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          socket.assigns.subject,
          expires_at
        )

      message =
        {:allow_access, {self(), socket_ref(socket)},
         %{
           client_id: socket.assigns.client.id,
           client_ipv4: socket.assigns.client.ipv4,
           client_ipv6: socket.assigns.client.ipv6,
           resource: resource,
           policy_authorization_id: policy_authorization_id,
           policy_id: policy_id,
           authorization_expires_at: expires_at,
           client_payload: payload
         }}

      policy_authorization = struct(Portal.PolicyAuthorization, attrs)

      case Portal.Queue.enqueue(:policy_authorization_queue, attrs,
             dispatch: fn ->
               PG.deliver(
                 gateway.id,
                 attach_policy_authorization(message, policy_authorization)
               )
             end
           ) do
        :ok ->
          {:noreply, socket}

        {:error, _reason} ->
          {:reply, {:error, %{reason: :offline}}, socket}
      end
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, :offline} ->
        {:reply, {:error, %{reason: :offline}}, socket}

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
           Presence.Gateways.fetch_gateway(socket.assigns.subject.account.id, gateway_id),
         true <- resource.site != nil and resource.site.id == Ecto.UUID.dump!(gateway.site_id) do
      policy_authorization_id = Ecto.UUID.generate()

      attrs =
        policy_authorization_attrs(
          policy_authorization_id,
          socket.assigns.client,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          socket.assigns.subject,
          expires_at
        )

      message =
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
           policy_authorization_id: policy_authorization_id,
           policy_id: policy_id,
           authorization_expires_at: expires_at
         }}

      policy_authorization = struct(Portal.PolicyAuthorization, attrs)

      case Portal.Queue.enqueue(:policy_authorization_queue, attrs,
             dispatch: fn ->
               PG.deliver(
                 gateway.id,
                 attach_policy_authorization(message, policy_authorization)
               )
             end
           ) do
        :ok ->
          {:noreply, socket}

        {:error, _reason} ->
          {:reply, {:error, %{reason: :offline}}, socket}
      end
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, :offline} ->
        {:reply, {:error, %{reason: :offline}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}

      false ->
        {:reply, {:error, %{reason: :offline}}, socket}
    end
  end

  def handle_in(
        "new_gateway_ice_candidates",
        %{"candidates" => candidates, "gateway_id" => gateway_id},
        socket
      ) do
    PG.deliver(gateway_id, {:ice_candidates, socket.assigns.client.id, candidates})
    {:noreply, socket}
  end

  def handle_in(
        "invalidate_gateway_ice_candidates",
        %{"candidates" => candidates, "gateway_id" => gateway_id},
        socket
      ) do
    PG.deliver(
      gateway_id,
      {:invalidate_ice_candidates, socket.assigns.client.id, candidates}
    )

    {:noreply, socket}
  end

  def handle_in(
        "new_client_ice_candidates",
        %{"candidates" => candidates, "client_id" => target_client_id},
        socket
      ) do
    with true <- client_to_client_enabled?(socket.assigns.subject.account),
         :ok <-
           PG.deliver(
             target_client_id,
             {:client_ice_candidates, socket.assigns.client.id, candidates}
           ) do
      {:noreply, socket}
    else
      false ->
        Logger.warning("Client-to-client communication is disabled, cannot send ICE candidates",
          client_id: socket.assigns.client.id,
          account_id: socket.assigns.client.account_id,
          account_slug: socket.assigns.subject.account.slug,
          target_client_id: target_client_id
        )

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_in(
        "invalidate_client_ice_candidates",
        %{"candidates" => candidates, "client_id" => target_client_id},
        socket
      ) do
    with true <- client_to_client_enabled?(socket.assigns.subject.account),
         :ok <-
           PG.deliver(
             target_client_id,
             {:invalidate_client_ice_candidates, socket.assigns.client.id, candidates}
           ) do
      {:noreply, socket}
    else
      false ->
        push(socket, "client_ice_candidate_error", %{
          client_id: target_client_id,
          reason: :disabled
        })

        {:noreply, socket}

      {:error, :not_found} ->
        push(socket, "client_ice_candidate_error", %{
          client_id: target_client_id,
          reason: :offline
        })

        {:noreply, socket}
    end
  end

  # !!! TODO: REMOVE BEFORE GA !!!
  # PoC-only shim kept for a customer until their clients migrate to the
  # `create_flow` path for static_device_pool resources. The handler enforces
  # pool membership only — the target IPv4 must be a member of *some* static
  # device pool the actor has connectable access to (via `cache.device_addresses`,
  # which is populated only from policy-authorized pools). It does NOT create a
  # `policy_authorization` row, so revocation/reauth/expiry are not tracked for
  # flows authorized this way. Remove this handler before GA.
  def handle_in("request_device_access", %{"ipv4" => ipv4_string}, socket) do
    account_id = socket.assigns.client.account_id

    with true <- client_to_client_enabled?(socket.assigns.subject.account),
         {:ok, {:ipv4, ipv4_tuple} = target} <-
           parse_target_address(%{"ipv4" => ipv4_string}),
         :ok <- legacy_authorize_device_access(socket.assigns.cache, ipv4_tuple),
         {:ok, target_client_id, target_meta} <-
           find_online_client_by_address(account_id, target),
         :ok <- check_peer_compatibility(target_meta, socket) do
      # PoC shim: bypass the Queue entirely because we don't persist a
      # `policy_authorization` row here. Deliver to the target first; the
      # initiator is released only once the target's channel acks (same
      # ordering guarantee as the `create_flow` pool path).
      ref = make_ref()

      {receiver_message, initiator_payload} =
        build_client_device_access_authorized_messages(
          target_client_id,
          target_meta,
          nil,
          nil,
          nil,
          nil,
          ref,
          socket
        )

      case PG.deliver(target_client_id, receiver_message) do
        :ok ->
          timer_ref =
            Process.send_after(self(), {:flow_creation_timeout, ref}, flow_creation_timeout())

          pending =
            Map.put(socket.assigns.pending_flows, ref, %{
              timer_ref: timer_ref,
              initiator_payload: initiator_payload,
              deny_payload: %{client_id: target_client_id, ipv4: ipv4_string, reason: :offline}
            })

          {:noreply, assign(socket, :pending_flows, pending)}

        {:error, :not_found} ->
          push(socket, "client_device_access_denied", %{
            client_id: target_client_id,
            ipv4: ipv4_string,
            reason: :offline
          })

          {:noreply, socket}
      end
    else
      false ->
        push(socket, "client_device_access_denied", %{
          ipv4: ipv4_string,
          reason: :disabled
        })

        {:noreply, socket}

      {:error, :version_mismatch} ->
        push(socket, "client_device_access_denied", %{
          ipv4: ipv4_string,
          reason: :version_mismatch
        })

        {:noreply, socket}

      {:error, :invalid_address} ->
        Logger.warning("Invalid IPv4 address provided for device access request",
          client_id: socket.assigns.client.id,
          account_id: socket.assigns.client.account_id,
          account_slug: socket.assigns.subject.account.slug,
          ipv4: ipv4_string
        )

        {:noreply, socket}

      :offline ->
        push(socket, "client_device_access_denied", %{ipv4: ipv4_string, reason: :offline})
        {:noreply, socket}

      {:error, :forbidden} ->
        push(socket, "client_device_access_denied", %{ipv4: ipv4_string, reason: :forbidden})
        {:noreply, socket}
    end
  end

  # The client pushes it's ICE candidates list and the list of gateways that need to receive it
  def handle_in(
        "broadcast_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    Enum.each(gateway_ids, fn gateway_id ->
      PG.deliver(
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
      PG.deliver(
        gateway_id,
        {:invalidate_ice_candidates, socket.assigns.client.id, candidates}
      )
    end)

    {:noreply, socket}
  end

  def handle_in("no_relays", _payload, socket) do
    {:ok, relays} = select_relays(socket)
    socket = cache_relays(socket, relays)

    push(socket, "relays_presence", %{
      disconnected_ids: [],
      connected:
        Views.Relay.render_many(
          relays,
          socket.assigns.session.public_key,
          socket.assigns.subject.expires_at
        )
    })

    {:noreply, socket}
  end

  # Catch-all for unknown messages
  def handle_in(message, payload, socket) do
    Logger.error("Unknown client message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  defp client_to_client_enabled?(account), do: Database.client_to_client_enabled?(account)

  # Reject peer connections when:
  #   - the target client predates `client_device_access_authorized` / `_denied`
  #     handling (older clients silently drop the message, leaving the initiator
  #     stuck waiting), or
  #   - initiator and target are on different minor versions — snownet's wire
  #     format may change on a minor cadence, so cross-minor pairs are unsafe.
  defp check_peer_compatibility(target_meta, socket) do
    target_user_agent = Map.get(target_meta, :user_agent)
    target_version = Map.get(target_meta, :version)
    initiator_version = socket.assigns.session.version

    if Portal.Version.supports_device_access?(target_user_agent, target_version) and
         Portal.Version.same_minor_version?(initiator_version, target_version) do
      :ok
    else
      {:error, :version_mismatch}
    end
  end

  # !!! TODO: REMOVE BEFORE GA — used only by the legacy `request_device_access` !!!
  # The check is "the IPv4 belongs to *some* device in a connectable pool we have
  # policy-authorized access to" — `cache.device_addresses` is only populated for
  # static_device_pool members of pools that passed `recompute_connectable_resources`,
  # so this is effectively a pool-membership-only authorization. Doesn't create a
  # `policy_authorization`. Remove alongside the handler before GA.
  defp legacy_authorize_device_access(cache, {_, _, _, _} = ipv4_tuple) do
    if Enum.any?(cache.device_addresses, fn {_, {v4, _v6}} -> v4 == ipv4_tuple end),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp parse_target_address(%{"ipv4" => ipv4, "ipv6" => ipv6})
       when is_binary(ipv4) and is_binary(ipv6),
       do: {:error, :ambiguous_address}

  defp parse_target_address(%{"ipv4" => ipv4_string}) when is_binary(ipv4_string) do
    case :inet.parse_address(String.to_charlist(ipv4_string)) do
      {:ok, {_, _, _, _} = tuple} -> {:ok, {:ipv4, tuple}}
      _ -> {:error, :invalid_address}
    end
  end

  defp parse_target_address(%{"ipv6" => ipv6_string}) when is_binary(ipv6_string) do
    case :inet.parse_address(String.to_charlist(ipv6_string)) do
      {:ok, {_, _, _, _, _, _, _, _} = tuple} -> {:ok, {:ipv6, tuple}}
      _ -> {:error, :invalid_address}
    end
  end

  defp parse_target_address(_), do: {:error, :missing_address}

  defp fetch_connectable_dynamic_pool(cache, resource_id) do
    rid_bytes = Ecto.UUID.dump!(resource_id)

    case Enum.find(cache.connectable_resources, &(&1.id == rid_bytes)) do
      %Cache.Cacheable.Resource{type: :dynamic_device_pool} = resource -> {:ok, resource}
      _ -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  # Dispatches the pool authorization check by resource type. Static pools have
  # their member set pre-loaded in the cache; dynamic pools resolve the target IP
  # to a device at request-time and verify its hostname against the pool pattern.
  defp authorize_pool_target(
         %Cache.Cacheable.Resource{type: :static_device_pool},
         cache,
         resource_id,
         target,
         _subject
       ) do
    Cache.Client.authorize_device_access(cache, resource_id, target)
  end

  defp authorize_pool_target(
         %Cache.Cacheable.Resource{type: :dynamic_device_pool, address: pattern},
         _cache,
         _resource_id,
         target,
         subject
       ) do
    with {:ok, %Portal.Device{} = device} <-
           Database.get_device_by_address(target, subject),
         true <- Portal.Resource.matches_dns_pattern?(pattern, device.hostname) do
      {:ok, device.id}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp find_online_client_by_address(account_id, {:ipv4, ipv4_tuple}) do
    case Presence.Clients.Account.find_by_ipv4(account_id, ipv4_tuple) do
      {target_client_id, target_meta} -> {:ok, target_client_id, target_meta}
      nil -> :offline
    end
  end

  defp find_online_client_by_address(account_id, {:ipv6, ipv6_tuple}) do
    case Presence.Clients.Account.find_by_ipv6(account_id, ipv6_tuple) do
      {target_client_id, target_meta} -> {:ok, target_client_id, target_meta}
      nil -> :offline
    end
  end

  defp handle_create_gateway_flow(
         resource_id,
         resource,
         membership_id,
         policy_id,
         expires_at,
         connected_gateway_ids,
         socket
       ) do
    case Database.all_compatible_gateways_for_client_and_resource(
           socket.assigns.client_version,
           resource,
           socket.assigns.subject.account.id
         ) do
      {:ok, [_ | _] = gateways} ->
        location = {
          socket.assigns.subject.context.remote_ip_location_lat,
          socket.assigns.subject.context.remote_ip_location_lon
        }

        gateway = Device.load_balance_gateways(location, gateways, connected_gateway_ids)
        gateway_public_key = gateway.latest_session.public_key

        policy_authorization_id = Ecto.UUID.generate()

        preshared_key =
          generate_preshared_key(
            socket.assigns.client,
            socket.assigns.session.public_key,
            gateway,
            gateway_public_key
          )

        ice_credentials =
          generate_ice_credentials(
            socket.assigns.session.public_key,
            socket.assigns.client,
            gateway,
            gateway_public_key
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
             policy_authorization_id: policy_authorization_id,
             policy_id: policy_id,
             authorization_expires_at: expires_at,
             ice_credentials: ice_credentials,
             preshared_key: preshared_key
           }}

        attrs =
          policy_authorization_attrs(
            policy_authorization_id,
            socket.assigns.client,
            gateway,
            resource_id,
            policy_id,
            membership_id,
            socket.assigns.subject,
            expires_at
          )

        policy_authorization = struct(Portal.PolicyAuthorization, attrs)

        case Portal.Queue.enqueue(:policy_authorization_queue, attrs,
               dispatch: fn ->
                 PG.deliver(
                   gateway.id,
                   attach_policy_authorization(message, policy_authorization)
                 )
               end
             ) do
          :ok ->
            timer_ref =
              Process.send_after(
                self(),
                {:flow_creation_timeout, resource_id},
                flow_creation_timeout()
              )

            socket =
              assign(
                socket,
                :pending_flows,
                Map.put(socket.assigns.pending_flows, resource_id, {timer_ref, policy_id})
              )

            {:noreply, socket}

          {:error, _reason} ->
            push(socket, "flow_creation_failed", %{resource_id: resource_id, reason: :offline})
            {:noreply, socket}
        end

      {:ok, []} ->
        push(socket, "flow_creation_failed", %{resource_id: resource_id, reason: :offline})
        {:noreply, socket}

      {:error, :version_mismatch} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :version_mismatch
        })

        {:noreply, socket}
    end
  end

  defp handle_create_pool_flow(
         resource_id,
         resource,
         membership_id,
         policy_id,
         expires_at,
         payload,
         socket
       ) do
    account_id = socket.assigns.client.account_id

    with true <- client_to_client_enabled?(socket.assigns.subject.account),
         {:ok, target} <- parse_target_address(payload),
         {:ok, target_device_id} <-
           authorize_pool_target(
             resource,
             socket.assigns.cache,
             resource_id,
             target,
             socket.assigns.subject
           ) do
      # Once the target IP is authorized for the pool we know the device id, so even
      # offline-target denials can carry it back to the initiator.
      case find_online_client_by_address(account_id, target) do
        {:ok, target_client_id, target_meta} ->
          handle_authorized_pool_target(
            target_client_id,
            target_meta,
            resource,
            membership_id,
            policy_id,
            expires_at,
            payload,
            socket
          )

        :offline ->
          push(socket, "client_device_access_denied", %{
            client_id: target_device_id,
            ipv4: payload["ipv4"],
            ipv6: payload["ipv6"],
            reason: :offline
          })

          {:noreply, socket}
      end
    else
      false ->
        push(socket, "client_device_access_denied", %{
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :disabled
        })

        {:noreply, socket}

      {:error, :ambiguous_address} ->
        Logger.warning("create_flow for pool included both ipv4 and ipv6",
          client_id: socket.assigns.client.id,
          resource_id: resource_id
        )

        push(socket, "client_device_access_denied", %{
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :ambiguous_address
        })

        {:noreply, socket}

      {:error, :missing_address} ->
        push(socket, "client_device_access_denied", %{
          resource_id: resource_id,
          reason: :missing_address
        })

        {:noreply, socket}

      {:error, :invalid_address} ->
        Logger.warning("Invalid IP address provided for pool device access request",
          client_id: socket.assigns.client.id,
          account_id: socket.assigns.client.account_id,
          account_slug: socket.assigns.subject.account.slug,
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"]
        )

        push(socket, "client_device_access_denied", %{
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :invalid_address
        })

        {:noreply, socket}

      {:error, :forbidden} ->
        push(socket, "client_device_access_denied", %{
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :forbidden
        })

        {:noreply, socket}
    end
  end

  # Target was found in presence — try delivery and persist the policy_authorization
  # only if delivery succeeds.
  defp handle_authorized_pool_target(
         target_client_id,
         target_meta,
         resource,
         membership_id,
         policy_id,
         expires_at,
         payload,
         socket
       ) do
    case check_peer_compatibility(target_meta, socket) do
      :ok ->
        deliver_pool_target_authorized(
          target_client_id,
          target_meta,
          resource,
          membership_id,
          policy_id,
          expires_at,
          payload,
          socket
        )

      {:error, :version_mismatch} ->
        push(socket, "client_device_access_denied", %{
          client_id: target_client_id,
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :version_mismatch
        })

        {:noreply, socket}
    end
  end

  defp deliver_pool_target_authorized(
         target_client_id,
         target_meta,
         resource,
         membership_id,
         policy_id,
         expires_at,
         payload,
         socket
       ) do
    resource_id = Ecto.UUID.load!(resource.id)
    policy_authorization_id = Ecto.UUID.generate()

    target_device = %Portal.Device{
      id: target_client_id,
      account_id: socket.assigns.client.account_id,
      type: :client,
      latest_session: %{remote_ip: target_meta.remote_ip}
    }

    attrs =
      policy_authorization_attrs(
        policy_authorization_id,
        socket.assigns.client,
        target_device,
        resource_id,
        policy_id,
        membership_id,
        socket.assigns.subject,
        expires_at
      )

    # Precompute the receiver-side and initiator-side messages BEFORE entering
    # the Queue dispatch callback. This keeps the dispatch callback minimal
    # (just `PG.deliver/2`) so it can't raise mid-execution: any crash in
    # crypto/render code happens up front, before any allow-equivalent message
    # is on the wire, and before the queue buffers an entry.
    #
    # `ref` correlates the target channel's ack back to this request. The
    # initiator is NOT released on `Queue.enqueue/3` returning `:ok` — it is
    # released only once the target's channel acks that it has pushed the
    # authorization onto the target's websocket (`{:device_access_acked, ref}`).
    # Until then the initiator must not start ICE, because its candidates
    # travel the same socket as the authorization and would otherwise race
    # ahead of it at the target's data plane.
    ref = make_ref()

    {receiver_message, initiator_payload} =
      build_client_device_access_authorized_messages(
        target_client_id,
        target_meta,
        resource,
        policy_authorization_id,
        policy_id,
        expires_at,
        ref,
        socket
      )

    policy_authorization = struct(Portal.PolicyAuthorization, attrs)

    case Portal.Queue.enqueue(:policy_authorization_queue, attrs,
           dispatch: fn ->
             PG.deliver(
               target_client_id,
               attach_policy_authorization(receiver_message, policy_authorization)
             )
           end
         ) do
      :ok ->
        timer_ref =
          Process.send_after(self(), {:flow_creation_timeout, ref}, flow_creation_timeout())

        pending =
          Map.put(socket.assigns.pending_flows, ref, %{
            timer_ref: timer_ref,
            initiator_payload: initiator_payload,
            deny_payload: %{
              client_id: target_client_id,
              ipv4: payload["ipv4"],
              ipv6: payload["ipv6"],
              reason: :offline
            }
          })

        {:noreply, assign(socket, :pending_flows, pending)}

      {:error, _} ->
        push(socket, "client_device_access_denied", %{
          client_id: target_client_id,
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :offline
        })

        {:noreply, socket}
    end
  end

  # Returns `{receiver_message, initiator_payload}`. The receiver_message goes
  # to the target client via PG (delivered inside the Queue's dispatch
  # callback so it shares a sender pid with any later `:reject_access`). It
  # carries `{ack_to, ref}` so the target's channel can ack back once it has
  # pushed the authorization onto the target's websocket; the initiator_payload
  # is released to the originating client only after that ack arrives.
  defp build_client_device_access_authorized_messages(
         target_client_id,
         target_meta,
         resource,
         policy_authorization_id,
         policy_id,
         expires_at,
         ref,
         socket
       ) do
    client = socket.assigns.client
    client_public_key = socket.assigns.session.public_key

    target_client = %Portal.Device{
      id: target_client_id,
      psk_base: target_meta.psk_base,
      type: :client
    }

    preshared_key =
      Portal.Crypto.psk(
        client,
        client_public_key,
        target_client,
        target_meta.public_key
      )

    ice_credentials =
      generate_ice_credentials(
        client_public_key,
        client,
        target_client,
        target_meta.public_key
      )

    # Mirror the gateway's `authorize_flow` payload on the receiver side: the
    # receiving client gets the full resource view (filters, type, name,
    # devices) plus the subject (actor) view, in addition to peer/ICE fields.
    # We render with the initiator's session here — for static_device_pool
    # resources the version-dependent codepaths in the resource view aren't
    # exercised (no site fields), so this is safe across version skew.
    rendered_resource =
      if resource, do: Views.Resource.render(resource, socket.assigns.session)

    rendered_subject = PortalAPI.Gateway.Views.Subject.render(socket.assigns.subject)

    receiver_message =
      {:client_device_access_authorized, {self(), ref},
       %{
         client_id: client.id,
         client_public_key: client_public_key,
         client_ipv4: client.ipv4,
         client_ipv6: client.ipv6,
         preshared_key: preshared_key,
         local_ice_credentials: ice_credentials.receiver,
         remote_ice_credentials: ice_credentials.initiator,
         ice_role: :controlled,
         resource: rendered_resource,
         subject: rendered_subject,
         policy_authorization_id: policy_authorization_id,
         policy_id: policy_id,
         authorization_expires_at: expires_at
       }}

    initiator_payload = %{
      client_id: target_client_id,
      client_public_key: target_meta.public_key,
      client_ipv4: %Postgrex.INET{address: target_meta.ipv4},
      client_ipv6: %Postgrex.INET{address: target_meta.ipv6},
      preshared_key: preshared_key,
      local_ice_credentials: ice_credentials.initiator,
      remote_ice_credentials: ice_credentials.receiver,
      ice_role: :controlling
    }

    {receiver_message, initiator_payload}
  end

  # TODO: Re-enable after verifying compatibility with older clients
  # defp render_ipv4s(ipv4s) do
  #   ipv4s
  #   |> Enum.map(&:inet.ntoa/1)
  #   |> Enum.map(&to_string/1)
  #   |> Enum.sort()
  # end

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

  defp init(socket, resources, relays) do
    push(socket, "init", %{
      resources: Views.Resource.render_many(resources, socket.assigns.session),
      authorizations:
        Views.PolicyAuthorization.render_many(socket.assigns.authorizations_cache),
      # TODO: Re-enable after verifying compatibility with older clients
      # authorized_ipv4s: render_ipv4s(cache.authorized_device_ipv4s),
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
  end

  defp reinitialize_client(socket) do
    {:ok, relays} = select_relays(socket)
    socket = cache_relays(socket, relays)

    init(socket, socket.assigns.cache.connectable_resources, relays)
    track_presence(socket)
  end

  defp generate_preshared_key(client, client_public_key, gateway, gateway_public_key) do
    Portal.Crypto.psk(client, client_public_key, gateway, gateway_public_key)
  end

  # ICE credentials must stay the same for all connections between an initiator and a receiver as long
  # as they do not lose their state, so we can leverage their public keys, which are reset on each
  # restart of an initiator or a receiver.
  defp generate_ice_credentials(initiator_pubkey, initiator, receiver, receiver_pubkey) do
    ice_credential_seed =
      [
        initiator.id,
        initiator_pubkey,
        receiver.id,
        receiver_pubkey
      ]
      |> Enum.join(":")

    ice_credential_seed_hash =
      :crypto.hash(:sha256, ice_credential_seed)
      |> Base.encode32(case: :lower, padding: false)

    [
      {:initiator_username, initiator_username},
      {:initiator_password, initiator_password},
      {:receiver_username, receiver_username},
      {:receiver_password, receiver_password}
    ] =
      Enum.map(
        [
          initiator_username: 0..3,
          initiator_password: 4..25,
          receiver_username: 26..29,
          receiver_password: 30..52
        ],
        fn {key, range} ->
          {key, String.slice(ice_credential_seed_hash, range)}
        end
      )

    %{
      initiator: %{username: initiator_username, password: initiator_password},
      receiver: %{username: receiver_username, password: receiver_password}
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
           old_struct: %Portal.Device{id: client_id} = old_client,
           struct: %Portal.Device{id: client_id} = client
         },
         %{assigns: %{client: %{id: id} = current_client}} = socket
       )
       when id == client_id do
    # Update socket with the new client state, preserving associations from the current socket.
    updated_client = %{
      client
      | account: current_client.account,
        actor: current_client.actor
    }

    socket = assign(socket, :client, updated_client)

    socket =
      if old_client.ipv4 != client.ipv4 or old_client.ipv6 != client.ipv6 do
        reinitialize_client(socket)
      else
        socket
      end

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
         %Change{op: :delete, old_struct: %Portal.Device{id: id}},
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

  # POLICY_AUTHORIZATIONS

  # When a policy_authorization is deleted where this client is the receiving device,
  # mirror the gateway flow: drop the cached authorization and push reject_access
  # with the {initiator, resource} pair so connlib tears down the inbound peer
  # connection. The wire shape parallels the gateway's reject_access rather than
  # client_device_access_denied (which is keyed on {ipv4, reason} for the
  # controlling-side denial path) — the receiver doesn't need a reason, only the
  # identity of the connection to drop.
  defp handle_change(
         %Change{
           op: :delete,
           old_struct:
             %Portal.PolicyAuthorization{receiving_device_id: client_id} =
               policy_authorization
         },
         %{assigns: %{client: %{id: client_id}}} = socket
       ) do
    socket = cancel_authz_durability_timer(socket, policy_authorization.id)
    revoke_policy_authorization(socket, policy_authorization)
  end

  # RESOURCES

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Resource{filters: old_filters},
           struct: %Portal.Resource{filters: filters} = resource
         },
         socket
       ) do
    maybe_push_resource_filters_updated(socket, resource, old_filters, filters)

    Cache.Client.update_resource(
      socket.assigns.cache,
      resource,
      socket.assigns.client,
      socket.assigns.session,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  # STATIC DEVICE POOL MEMBERS

  defp handle_change(
         %Change{op: :insert, struct: %Portal.StaticDevicePoolMember{} = member},
         socket
       ) do
    Cache.Client.add_static_device_pool_member(
      socket.assigns.cache,
      member,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.StaticDevicePoolMember{} = member},
         socket
       ) do
    {:ok, denied, added, removed_ids, cache} =
      Cache.Client.delete_static_device_pool_member(socket.assigns.cache, member)

    push_device_access_denied(socket, denied)
    push_resource_updates({:ok, added, removed_ids, cache}, socket)
  end

  # NON-SELF CLIENT DEVICES (members of a pool we have access to)

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Device{type: :client},
           struct: %Portal.Device{type: :client} = device
         },
         socket
       ) do
    Cache.Client.handle_member_device_update(
      socket.assigns.cache,
      device,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.Device{type: :client} = device},
         socket
       ) do
    {:ok, denied, added, removed_ids, cache} =
      Cache.Client.handle_member_device_delete(socket.assigns.cache, device)

    push_device_access_denied(socket, denied)
    push_resource_updates({:ok, added, removed_ids, cache}, socket)
  end

  defp handle_change(%Change{}, socket), do: {:noreply, socket}

  # Shared eviction path for the CDC delete handler, the direct `:reject_access`
  # from `Portal.Queue`'s on_failed callback, and the authz durability timeout.
  # Drop the cached authorization and, if it was still active, push
  # `reject_access` so connlib tears down the inbound peer connection. The peer
  # recovers by tripping ICMP "destination prohibited" and requesting a fresh
  # flow. Deletes of already-expired authorizations (the
  # `DeleteExpiredPolicyAuthorizations` reaper) are dropped silently — connlib
  # has already expired them locally.
  defp revoke_policy_authorization(socket, %Portal.PolicyAuthorization{id: id}) do
    case Cache.Client.Authorizations.delete(socket.assigns.authorizations_cache, id) do
      {:ok, initiating_client_id, resource_id, expires_at_unix, authorizations_cache} ->
        now_unix = DateTime.utc_now() |> DateTime.to_unix(:second)

        if expires_at_unix > now_unix do
          push(socket, "reject_access", %{
            client_id: initiating_client_id,
            resource_id: resource_id
          })
        end

        {:noreply, assign(socket, authorizations_cache: authorizations_cache)}

      :error ->
        {:noreply, socket}
    end
  end

  # Authz durability timer for fail-closed cleanup when the originating queue
  # loses state. See gateway channel's equivalent helpers for full rationale,
  # including the rationale for the generation token in `authz_durability`.
  @authz_durability_timeout :timer.seconds(15)

  defp arm_session_durability_timer(socket) do
    case socket.assigns.session.id do
      nil ->
        socket

      session_id ->
        generation = make_ref()

        timer_ref =
          Process.send_after(
            self(),
            {:session_durability_timeout, session_id, generation},
            @session_durability_timeout
          )

        # Fail-safe: if the session queue never confirms the DB flush, the
        # channel disconnects and lets the client reconnect to create a new row.
        assign(socket, session_durability: {session_id, generation, timer_ref})
    end
  end

  defp cancel_session_durability_timer(socket, session_id) do
    case socket.assigns[:session_durability] do
      {^session_id, _generation, timer_ref} ->
        Process.cancel_timer(timer_ref)
        assign(socket, session_durability: nil)

      _ ->
        socket
    end
  end

  defp maybe_arm_authz_durability_timer(socket, nil), do: socket

  defp maybe_arm_authz_durability_timer(socket, %Portal.PolicyAuthorization{} = pa) do
    generation = make_ref()

    timer_ref =
      Process.send_after(self(), {:authz_durability_timeout, pa, generation}, @authz_durability_timeout)

    pending = socket.assigns[:authz_durability] || %{}

    case Map.get(pending, pa.id) do
      nil -> :ok
      {_old_generation, old_ref} -> Process.cancel_timer(old_ref)
    end

    assign(socket, authz_durability: Map.put(pending, pa.id, {generation, timer_ref}))
  end

  defp cancel_authz_durability_timer(socket, authz_id) do
    pending = socket.assigns[:authz_durability] || %{}

    case Map.pop(pending, authz_id) do
      {nil, _} ->
        socket

      {{_generation, timer_ref}, rest} ->
        Process.cancel_timer(timer_ref)
        assign(socket, authz_durability: rest)
    end
  end

  defp push_device_access_denied(_socket, nil), do: :ok

  defp push_device_access_denied(socket, {ipv4_tuple, ipv6_tuple}) do
    push(socket, "client_device_access_denied", %{
      ipv4: to_string(:inet.ntoa(ipv4_tuple)),
      ipv6: to_string(:inet.ntoa(ipv6_tuple)),
      reason: :forbidden
    })

    :ok
  end

  defp maybe_put_authorization(
         cache,
         client_id,
         %{id: resource_id},
         paid,
         policy_id,
         %DateTime{} = expires_at
       )
       when not is_nil(client_id) and not is_nil(paid) do
    Cache.Client.Authorizations.put(cache, paid, client_id, resource_id, policy_id, expires_at)
  end

  defp maybe_put_authorization(cache, _client_id, _resource, _paid, _policy_id, _expires_at),
    do: cache

  defp maybe_push_resource_filters_updated(_socket, _resource, filters, filters), do: :ok

  defp maybe_push_resource_filters_updated(socket, resource, _old_filters, _filters) do
    if Cache.Client.Authorizations.has_resource?(socket.assigns.authorizations_cache, resource.id) do
      cacheable = Cache.Cacheable.to_cache(resource)
      push(socket, "resource_filters_updated", Views.Resource.render_authorization(cacheable))
    end

    :ok
  end

  defp push_resource_updates({:ok, added_resources, removed_ids, cache}, socket) do
    # Currently, connlib doesn't handle resources changing sites, so we need to delete then create.
    # We handle that scenario by sending resource_deleted then resource_created_or_updated, so it's
    # important that deletions are processed first here.
    # See https://github.com/firezone/firezone/issues/9881
    for resource_id <- removed_ids do
      push(socket, "resource_deleted", resource_id)
    end

    for resource <- added_resources do
      push(
        socket,
        "resource_created_or_updated",
        Views.Resource.render(resource, socket.assigns.session)
      )
    end

    {:noreply, assign(socket, cache: cache)}
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

  # Builds the attrs map for a `Portal.PolicyAuthorization` row. The caller
  # passes this to `Portal.Queue.enqueue/3` with a `:dispatch` callback that
  # delivers the corresponding `:allow_access` (or equivalent) message to the
  # gateway. Routing the dispatch through the Queue process ensures that
  # `:allow_access` and any later `:reject_access` (from the Queue's
  # `:on_failed` callback when the insert fails FK) share a sender pid, so the
  # gateway sees them in send order.
  defp policy_authorization_attrs(
         policy_authorization_id,
         %Portal.Device{
           id: client_id,
           account_id: account_id,
           actor_id: actor_id
         },
         %{
           id: receiving_device_id,
           account_id: account_id,
           latest_session: %{remote_ip: receiver_remote_ip}
         },
         resource_id,
         policy_id,
         membership_id,
         %Authentication.Subject{
           account: %{id: account_id},
           actor: %{id: actor_id},
           credential: %{id: token_id},
           context: %Authentication.Context{
             remote_ip: initiator_remote_ip,
             user_agent: initiator_user_agent
           }
         },
         expires_at
       ) do
    %{
      id: policy_authorization_id,
      token_id: token_id,
      policy_id: policy_id,
      initiating_device_id: client_id,
      receiving_device_id: receiving_device_id,
      resource_id: resource_id,
      membership_id: membership_id,
      account_id: account_id,
      initiator_remote_ip: initiator_remote_ip,
      initiator_user_agent: initiator_user_agent,
      receiver_remote_ip: receiver_remote_ip,
      expires_at: expires_at
    }
  end

  # Attaches a synthetic `%Portal.PolicyAuthorization{}` to a receiver-side
  # allow message. The receiver uses it to:
  #   1. Arm an authz durability timer keyed by `pa.id`, so that if no
  #      `:confirm_authz_durability` (queue flush success) or `:reject_access`
  #      (queue flush failure) arrives within the timeout window, the
  #      receiver fail-closes by running the same eviction path used for
  #      `:reject_access`.
  #   2. On the eviction path itself (CDC delete, on_failed reject, authz
  #      durability timer fire), reuse the struct's id to drop the cached
  #      authorization and push `reject_access`.
  #
  # All peer-bound messages carry a `{channel_pid, ref}` reply tuple:
  # `{tag, {channel_pid, ref}, payload}` (used by :allow_access,
  # :authorize_policy, :request_connection, and :client_device_access_authorized).
  defp attach_policy_authorization({tag, ref_tuple, payload}, %Portal.PolicyAuthorization{} = pa)
       when is_tuple(ref_tuple) do
    {tag, ref_tuple, Map.put(payload, :policy_authorization, pa)}
  end

  defp flow_creation_timeout do
    Portal.Config.get_env(:portal, :flow_creation_timeout_ms, :timer.seconds(15))
  end

  defp schedule_session_expiry(expires_at) do
    ms = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    Process.send_after(self(), :disconnect, max(ms, 0))
  end

  defp register(socket) do
    current_pid = socket.assigns[:pg_scope_pid]

    case PG.scope_pid() do
      nil ->
        Logger.error("Portal.PG scope is not running, retrying registration shortly")
        Process.send_after(self(), :register, 50)
        {:noreply, socket}

      ^current_pid ->
        # We're already registered
        {:noreply, socket}

      new_pid ->
        Process.monitor(new_pid)
        :ok = PG.register(socket.assigns.client.id)
        :ok = PG.join(socket.assigns.subject.credential.id)
        socket = assign(socket, :pg_scope_pid, new_pid)

        # Only enqueue + arm on the first successful registration; re-registrations
        # after a PG scope crash share the same channel and session row.
        if is_nil(current_pid) do
          Portal.Queue.enqueue(:client_session_queue, session_attrs(socket.assigns.session))
          {:noreply, arm_session_durability_timer(socket)}
        else
          {:noreply, socket}
        end
    end
  end

  # Tracks client presence and monitors Presence tracker shard processes so we
  # can re-track if any crash. Monitoring the supervisor alone is insufficient
  # because individual shard crashes under :one_for_one don't kill the supervisor.
  defp track_presence(socket) do
    case Process.whereis(Portal.Presence) do
      nil ->
        Process.send_after(self(), :track_presence, 50)
        socket

      sup_pid ->
        session_meta = %{
          ipv4: socket.assigns.client.ipv4.address,
          ipv6: socket.assigns.client.ipv6.address,
          name: socket.assigns.client.name,
          public_key: socket.assigns.session.public_key,
          psk_base: socket.assigns.client.psk_base,
          remote_ip: socket.assigns.session.remote_ip,
          version: socket.assigns.session.version,
          user_agent: socket.assigns.session.user_agent
        }

        :ok =
          Presence.Clients.connect(
            socket.assigns.client,
            socket.assigns.subject.credential.id,
            session_meta
          )

        for {_pid, ref} <- socket.assigns[:presence_monitors] || [] do
          Process.demonitor(ref, [:flush])
        end

        monitors =
          for {_, pid, _, _} <- Supervisor.which_children(sup_pid), is_pid(pid) do
            {pid, Process.monitor(pid)}
          end

        assign(socket, presence_monitors: monitors)
    end
  end

  defp session_attrs(%Portal.ClientSession{} = session) do
    session
    |> Map.from_struct()
    |> Map.drop([:__meta__, :account, :device, :client_token])
  end

  defp abnormal_exit?(:normal), do: false
  defp abnormal_exit?(:shutdown), do: false
  defp abnormal_exit?({:shutdown, _reason}), do: false
  defp abnormal_exit?(_reason), do: true

  defmodule Database do
    import Ecto.Query, only: [from: 2]

    alias Portal.Features

    def client_to_client_enabled?(account) do
      query = from(f in Features, where: f.feature == :client_to_client and f.enabled == true)

      account_feature_enabled? = account.features.client_to_client == true

      Portal.Safe.unscoped(query, :replica) |> Portal.Safe.exists?() and account_feature_enabled?
    end

    def all_compatible_gateways_for_client_and_resource(
          client_version,
          resource,
          account_id
        ) do
      resource_site_id = site_id_from_resource(resource)

      site_gateways =
        Portal.Presence.Gateways.all_connected_gateways(account_id)
        |> Enum.filter(&(&1.site_id == resource_site_id))

      compatible_gateways =
        filter_compatible_gateways(site_gateways, resource, client_version)

      cond do
        compatible_gateways != [] ->
          {:ok, compatible_gateways}

        site_gateways != [] ->
          {:error, :version_mismatch}

        true ->
          {:ok, []}
      end
    end

    @doc """
      Fetches a client device by hostname within the subject's account. The hostname
      column is `citext`, so equality is case-insensitive at the DB layer.

      Used by the dynamic device pool DNS resolution path. Returns `{:error, :not_found}`
      for a miss or unauthorized read; the caller is expected to also verify the device's
      hostname matches the pool's address pattern before returning IPs to the client.
    """
    def get_device_by_hostname(hostname, subject) when is_binary(hostname) do
      from(d in Portal.Device,
        where: d.type == :client,
        where: d.hostname == ^hostname
      )
      |> Portal.Safe.scoped(subject, :replica)
      |> Portal.Safe.one()
      |> case do
        %Portal.Device{} = device -> {:ok, device}
        _ -> {:error, :not_found}
      end
    end

    @doc """
      Fetches a client device by its tunnel IPv4 or IPv6 within the subject's account.
      Used to authorize a `create_flow` against a dynamic device pool: we resolve the
      target IP to a device and let the caller verify the device's hostname matches
      the pool's address pattern.
    """
    def get_device_by_address({:ipv4, ipv4_tuple}, subject) do
      fetch_device_by_inet(:ipv4, %Postgrex.INET{address: ipv4_tuple}, subject)
    end

    def get_device_by_address({:ipv6, ipv6_tuple}, subject) do
      fetch_device_by_inet(:ipv6, %Postgrex.INET{address: ipv6_tuple}, subject)
    end

    defp fetch_device_by_inet(family, %Postgrex.INET{} = inet, subject) do
      query =
        case family do
          :ipv4 ->
            from(d in Portal.Device,
              where: d.type == :client,
              where: fragment("host(?) = host(?)", d.ipv4, ^inet)
            )

          :ipv6 ->
            from(d in Portal.Device,
              where: d.type == :client,
              where: fragment("host(?) = host(?)", d.ipv6, ^inet)
            )
        end

      query
      |> Portal.Safe.scoped(subject, :replica)
      |> Portal.Safe.one()
      |> case do
        %Portal.Device{} = device -> {:ok, device}
        _ -> {:error, :not_found}
      end
    end

    # Filters gateways by the resource type, gateway version, and client version.
    defp filter_compatible_gateways(gateways, _resource, nil), do: gateways

    defp filter_compatible_gateways(gateways, resource, client_version) do
      case Version.parse(client_version) do
        {:ok, version} ->
          Enum.filter(gateways, &compatible_gateway?(&1, resource, version))

        :error ->
          []
      end
    end

    defp compatible_gateway?(gateway, resource, version) do
      gateway_version_str = gateway.latest_session && gateway.latest_session.version

      case gateway_version_str && Version.parse(gateway_version_str) do
        {:ok, gateway_version} ->
          Version.match?(gateway_version, ">= #{version.major}.#{version.minor - 1}.0") and
            Version.match?(gateway_version, "< #{version.major}.#{version.minor + 2}.0") and
            not is_nil(Portal.Resource.adapt_resource_for_version(resource, gateway_version_str))

        _ ->
          false
      end
    end

    defp site_id_from_resource(%Portal.Cache.Cacheable.Resource{site: site}) do
      Ecto.UUID.load!(site.id)
    end
  end
end
