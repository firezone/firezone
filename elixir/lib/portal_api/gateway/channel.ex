defmodule PortalAPI.Gateway.Channel do
  use PortalAPI, :channel
  alias PortalAPI.Gateway.Views
  alias __MODULE__.Database

  alias Portal.{
    Account,
    Cache,
    Device,
    PG,
    Changes.Change,
    PubSub,
    Resource,
    Presence
  }

  require Logger

  # The interval at which the policy authorization cache is pruned.
  @prune_cache_every :timer.minutes(1)

  @session_durability_timeout :timer.seconds(15)

  # Relay credentials must be stable across reconnects so that gateways
  # don't see credential changes on every websocket connect. We use a fixed
  # far-future date rather than a dynamic offset from now.
  @relay_credentials_expire_at ~U[2038-01-01 00:00:00Z]

  @doc """
  Self-heal escape hatch. Pushes `reject_access` to a gateway's data plane
  for the given `(client_id, resource_id)` pair and clears the matching
  local cache entries.

  ## Not expected to be hit in production

  Every natural production code path that ends in `reject_access` on the
  gateway's data plane goes through `revoke_policy_authorization/2` first,
  which evicts the cached authorization by id and pushes reject:

    * CDC delete of a `policy_authorization` row — the row was really deleted.
    * `Portal.Queue`'s `:on_failed` callback — the insert failed FK, which
      means a parent row is gone.
    * Receiver-side authz durability timer — the queue died before flush.

  In every one of those, the only way reject reaches connlib is when the
  underlying authorization truly no longer exists. The synthetic case this
  function produces — "deliver reject for a pair the DB still authorizes" —
  has no natural production trigger.

  ## Why it exists

  The authz durability timer is our fail-closed guarantee: if a queue crashes
  before flushing, the cached authz on the receiver eventually triggers
  a reject so the gateway stops authorizing packets for an authz that
  has no DB row backing it. The client recovers by tripping ICMP
  prohibited and requesting a fresh flow through the normal portal
  path — closing the loop.

  This function is the manual version of that fail-closed signal. If the
  gateway's local cache ever desyncs from production state (a bug, a
  partial flush we didn't anticipate, an ops mistake), this lets us
  trigger the same fail-closed → ICMP → re-authorize recovery without
  waiting for a queue to crash or for the authz durability timer to time out.

  Integration tests use it to exercise the
  `icmp_error_unreachable_prohibited_create_new_flow` recovery path
  end-to-end: the test asserts that even when the gateway is forced into
  a fail-closed state for a pair, the client correctly recovers and
  re-authorizes via the portal.

  Do not call from production code paths.
  """
  def revoke_pair_access(gateway_id, client_id, resource_id) do
    Portal.PG.deliver(gateway_id, {:revoke_pair_access, client_id, resource_id})
  end

  @impl true
  def join("gateway", _payload, socket) do
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

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def handle_info(:after_join, socket) do
    # Initialize the cache
    socket =
      assign(socket,
        cache: Cache.Gateway.hydrate(socket.assigns.gateway),
        iceless_capable: false
      )

    Process.send_after(self(), :prune_cache, @prune_cache_every)

    # Track gateway's presence
    gateway = socket.assigns.gateway

    Logger.debug("Tracking gateway presence",
      gateway_id: gateway.id,
      site_id: gateway.site_id,
      account_id: gateway.account_id,
      token_id: socket.assigns.token_id
    )

    # Track gateway presence and monitor tracker shard processes for crash recovery
    socket = track_presence(socket)

    :ok = PubSub.Changes.subscribe(socket.assigns.gateway.account_id)

    {:noreply, socket} = register(socket)

    # Return all connected relays and subscribe to global relay presence
    {:ok, relays} = select_relays(socket)
    :ok = Presence.Relays.Global.subscribe()

    account = Database.get_account_by_id!(socket.assigns.gateway.account_id)

    socket = assign(socket, :account, account)

    init(socket, account, relays)

    # Cache relay IDs and stamp secrets for tracking
    socket = cache_relays(socket, relays)

    {:noreply, socket}
  end

  def handle_info(:prune_cache, socket) do
    Process.send_after(self(), :prune_cache, @prune_cache_every)
    {:noreply, assign(socket, cache: Cache.Gateway.prune(socket.assigns.cache))}
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
  #### Reacting to relay presence ####
  ####################################

  # Handle relay presence changes from global topic.
  # Instead of reacting immediately, we debounce by scheduling a delayed check.
  # This avoids spurious updates during transient relay disconnections.
  @impl true
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
  # cached_relay_ids is a MapSet of relay IDs we've sent to the gateway.
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
          socket.assigns.session.remote_ip_location_lat,
          socket.assigns.session.remote_ip_location_lon
        }

        relays = load_balance_relays(location, all_online_relays)
        socket = cache_relays(socket, relays)

        push(socket, "relays_presence", %{
          disconnected_ids: disconnected_ids,
          connected:
            Views.Relay.render_many(
              relays,
              socket.assigns.session.public_key,
              @relay_credentials_expire_at
            )
        })

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end
  end

  ###########################
  #### Connection setup #####
  ###########################

  def handle_info({:ice_candidates, client_id, candidates}, socket) do
    push(socket, "ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info({:invalidate_ice_candidates, client_id, candidates}, socket) do
    push(socket, "invalidate_ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info({:authorize_policy, {channel_pid, socket_ref}, payload}, socket) do
    %{
      client: client,
      subject: subject,
      resource: resource,
      policy_authorization_id: policy_authorization_id,
      authorization_expires_at: authorization_expires_at,
      ice_credentials: ice_credentials,
      preshared_key: preshared_key
    } = payload

    initiator_iceless_capable = Map.get(payload, :initiator_iceless_capable, false)
    flow_logs_ingest_token = Map.get(payload, :flow_logs_ingest_token)

    rid_bytes = Ecto.UUID.dump!(resource.id)

    use_iceless =
      socket.assigns.iceless_capable == true and initiator_iceless_capable == true and
        Account.iceless_enabled?(socket.assigns.account)

    ref =
      encode_ref(socket, {
        channel_pid,
        socket_ref,
        rid_bytes,
        preshared_key,
        ice_credentials,
        use_iceless
      })

    push(socket, "authorize_flow", %{
      ref: ref,
      resource: resource,
      gateway_ice_credentials: ice_credentials.receiver,
      client: client,
      client_ice_credentials: ice_credentials.initiator,
      expires_at: DateTime.to_unix(authorization_expires_at, :second),
      subject: subject,
      use_iceless: use_iceless,
      flow_logs_ingest_token: flow_logs_ingest_token
    })

    cache =
      socket.assigns.cache
      |> Cache.Gateway.put(
        policy_authorization_id,
        client.id,
        resource.id,
        authorization_expires_at
      )

    socket =
      socket
      |> assign(cache: cache)
      |> maybe_arm_authz_durability_timer(payload[:policy_authorization])

    {:noreply, socket}
  end

  # DEPRECATED IN 1.4
  def handle_info({:allow_access, {channel_pid, socket_ref}, attrs}, socket) do
    %{
      client_id: client_id,
      client_ipv4: client_ipv4,
      client_ipv6: client_ipv6,
      resource: %Cache.Cacheable.Resource{} = resource,
      policy_authorization_id: policy_authorization_id,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload
    } = attrs

    case Resource.adapt_resource_for_version(resource, socket.assigns.session.version) do
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
          client_id: client_id,
          resource: Views.Resource.render(resource),
          expires_at: DateTime.to_unix(authorization_expires_at, :second),
          payload: payload,
          client_ipv4: client_ipv4,
          client_ipv6: client_ipv6
        })

        cache =
          socket.assigns.cache
          |> Cache.Gateway.put(
            policy_authorization_id,
            client_id,
            resource.id,
            authorization_expires_at
          )

        socket =
          socket
          |> assign(cache: cache)
          |> maybe_arm_authz_durability_timer(attrs[:policy_authorization])

        {:noreply, socket}
    end
  end

  # DEPRECATED IN 1.4
  def handle_info({:request_connection, {channel_pid, socket_ref}, attrs}, socket) do
    %{
      client: client,
      resource: %Cache.Cacheable.Resource{} = resource,
      policy_authorization_id: policy_authorization_id,
      authorization_expires_at: authorization_expires_at
    } = attrs

    case Resource.adapt_resource_for_version(resource, socket.assigns.session.version) do
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
          client: client,
          expires_at: DateTime.to_unix(authorization_expires_at, :second)
        })

        cache =
          socket.assigns.cache
          |> Cache.Gateway.put(
            policy_authorization_id,
            client.id,
            resource.id,
            authorization_expires_at
          )

        socket =
          socket
          |> assign(cache: cache)
          |> maybe_arm_authz_durability_timer(attrs[:policy_authorization])

        {:noreply, socket}
    end
  end

  # Direct revocation from `Portal.Queue`'s on_failed path — a policy
  # authorization that we already announced via `:allow_access` /
  # `:authorize_policy` failed to persist. We reuse the same eviction path the
  # CDC delete handler uses: drop the cached authorization and push
  # `reject_access` so connlib tears down the flow.
  def handle_info({:reject_access, %Portal.PolicyAuthorization{} = policy_authorization}, socket) do
    socket = cancel_authz_durability_timer(socket, policy_authorization.id)
    revoke_policy_authorization(socket, policy_authorization)
  end

  # Queue confirms a policy_authorization was durably persisted — cancel the
  # corresponding authz durability timer so the receiver doesn't revoke a valid
  # authorization.
  def handle_info({:confirm_authz_durability, authz_id}, socket) do
    {:noreply, cancel_authz_durability_timer(socket, authz_id)}
  end

  def handle_info({:confirm_session_durability, session_id}, socket) do
    {:noreply, cancel_session_durability_timer(socket, session_id)}
  end

  # Authz durability timer fired — no `:confirm_authz_durability` or
  # `:reject_access` arrived within the timeout window. Treat as
  # "originating queue lost state" and run the same eviction path as
  # `:reject_access` (fail-closed). Logged at warning level because this
  # path firing means something went wrong upstream.
  #
  # The generation check guards against the race where this timer fires
  # right before a `:confirm_authz_durability` arrives: the cancel returned
  # false because the message was already in the mailbox, but the entry
  # for `pa.id` in `authz_durability` was either removed (durability
  # confirmed/rejected) or replaced (new timer for the same authz_id),
  # so the generation no longer matches. In that case, we ignore.
  def handle_info(
        {:authz_durability_timeout, %Portal.PolicyAuthorization{} = pa, generation},
        socket
      ) do
    case Map.get(socket.assigns[:authz_durability] || %{}, pa.id) do
      {^generation, _ref} ->
        Logger.warning(
          "Authz durability timeout firing for authz #{inspect(pa.id)} — queue never confirmed durability"
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
          "Gateway session #{inspect(session_id)} was not confirmed durable; disconnecting"
        )

        # Avoid sending "token_expired" since that will tear down connlib
        # state in the gateway. Instead, the gateway must reconnect.
        {:stop, :shutdown, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # Handler for the public `revoke_pair_access/3` self-heal helper.
  def handle_info({:revoke_pair_access, client_id, resource_id}, socket) do
    push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})

    key = {Ecto.UUID.dump!(client_id), Ecto.UUID.dump!(resource_id)}

    # Cancel any pending authz durability timer for the cached authz of this pair
    # so it doesn't fire later, find the cache empty, and log a spurious warning.
    socket =
      case Map.get(socket.assigns.cache, key) do
        {pa_id_bytes, _exp} ->
          cancel_authz_durability_timer(socket, Ecto.UUID.load!(pa_id_bytes))

        nil ->
          socket
      end

    cache = Map.delete(socket.assigns.cache, key)
    {:noreply, assign(socket, cache: cache)}
  end

  def handle_info(:disconnect, socket) do
    # Important: We push disconnect before closing the socket to prevent the gateway from
    # attempting to immediately reconnect
    push(socket, "disconnect", %{reason: "token_expired"})
    {:stop, :shutdown, socket}
  end

  # Another channel joined our gateway id group: a duplicate connection raced
  # past the connect-time check. First wins — we were here first, so tell the
  # newcomers to disconnect (their :disconnect handler pushes token_expired
  # and stops). Two simultaneous cross-node joins can each observe the other
  # and boot each other, but gateway reconnect backoff jitter settles that
  # within a round or two.
  def handle_info({_ref, :join, gateway_id, pids}, socket)
      when gateway_id == socket.assigns.gateway.id do
    for pid <- pids, pid != self() do
      Logger.info("Disconnecting duplicate gateway connection",
        gateway_id: socket.assigns.gateway.id
      )

      send(pid, :disconnect)
    end

    {:noreply, socket}
  end

  def handle_info({_ref, :leave, gateway_id, _pids}, socket)
      when gateway_id == socket.assigns.gateway.id do
    {:noreply, socket}
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

  @impl true
  def handle_in("flow_authorized", %{"ref" => signed_ref}, socket) do
    case decode_ref(socket, signed_ref) do
      {:ok, ref_tuple} ->
        {channel_pid, socket_ref, resource_id, preshared_key, ice_credentials, use_iceless} =
          ref_tuple

        send(
          channel_pid,
          {
            :connect,
            socket_ref,
            resource_id,
            socket.assigns.gateway.site_id,
            socket.assigns.gateway.id,
            socket.assigns.session.public_key,
            socket.assigns.gateway.ipv4,
            socket.assigns.gateway.ipv6,
            preshared_key,
            ice_credentials,
            use_iceless
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
          {:connect, socket_ref, rid_bytes, socket.assigns.session.public_key, payload}
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
    Enum.each(client_ids, fn client_id ->
      PG.deliver(
        client_id,
        {:ice_candidates, socket.assigns.gateway.id, candidates}
      )
    end)

    {:noreply, socket}
  end

  def handle_in(
        "broadcast_invalidated_ice_candidates",
        %{"candidates" => candidates, "client_ids" => client_ids},
        socket
      ) do
    Enum.each(client_ids, fn client_id ->
      PG.deliver(
        client_id,
        {:invalidate_ice_candidates, socket.assigns.gateway.id, candidates}
      )
    end)

    {:noreply, socket}
  end

  def handle_in("set_snownet_capabilities", payload, socket) when is_map(payload) do
    {:noreply, assign(socket, iceless_capable: payload["iceless"] == true)}
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
          @relay_credentials_expire_at
        )
    })

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
      Presence.Relays.all_connected_relays(except_ids)

    location = {
      socket.assigns.session.remote_ip_location_lat,
      socket.assigns.session.remote_ip_location_lon
    }

    relays = load_balance_relays(location, relays)

    {:ok, relays}
  end

  defp cache_relays(socket, relays) do
    cached_relay_ids = MapSet.new(relays, fn relay -> relay.id end)
    assign(socket, :cached_relay_ids, cached_relay_ids)
  end

  defp init(socket, account, relays) do
    push(socket, "init", %{
      flow_logs: flow_logs_config(),
      authorizations: Views.PolicyAuthorization.render_many(socket.assigns.cache),
      account_slug: account.slug,
      interface: Views.Interface.render(socket.assigns.gateway),
      relays:
        Views.Relay.render_many(
          relays,
          socket.assigns.session.public_key,
          @relay_credentials_expire_at
        ),
      # These aren't used but needed for API compatibility
      config: %{
        ipv4_masquerade_enabled: true,
        ipv6_masquerade_enabled: true
      }
    })
  end

  defp flow_logs_config do
    %{
      api_url: Portal.Config.fetch_env!(:portal, :flow_logs_api_url),
      upload_interval_secs: Portal.Config.fetch_env!(:portal, :flow_logs_upload_interval_secs),
      upload_batch_size: Portal.Config.fetch_env!(:portal, :flow_logs_upload_batch_size)
    }
  end

  defp reinitialize_gateway(socket) do
    {:ok, relays} = select_relays(socket)
    socket = cache_relays(socket, relays)
    account = Database.get_account_by_id!(socket.assigns.gateway.account_id)

    init(socket, account, relays)
    socket
  end

  ##########################################
  #### Handling changes from the domain ####
  ##########################################

  # ACCOUNTS

  # Resend init when config changes so that new slug may be applied
  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Account{slug: old_slug},
           struct: %Portal.Account{slug: slug} = account
         },
         socket
       ) do
    socket = assign(socket, :account, account)

    if old_slug != slug do
      {:ok, relays} = select_relays(socket)
      init(socket, account, relays)
    end

    {:noreply, socket}
  end

  # POLICY_AUTHORIZATIONS

  defp handle_change(
         %Change{
           op: :delete,
           old_struct:
             %Portal.PolicyAuthorization{receiving_device_id: gateway_id} =
               policy_authorization
         },
         %{
           assigns: %{gateway: %{id: gateway_id}}
         } = socket
       ) do
    socket = cancel_authz_durability_timer(socket, policy_authorization.id)
    revoke_policy_authorization(socket, policy_authorization)
  end

  # GATEWAYS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Device{id: gateway_id} = old_gateway,
           struct: %Device{id: gateway_id} = gateway
         },
         %{
           assigns: %{gateway: %{id: gateway_id} = current_gateway}
         } = socket
       ) do
    gateway = %{gateway | site: current_gateway.site}
    socket = assign(socket, :gateway, gateway)

    socket =
      if old_gateway.ipv4 != gateway.ipv4 or old_gateway.ipv6 != gateway.ipv6 do
        reinitialize_gateway(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Device{id: gateway_id}
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
           old_struct: %Portal.Resource{
             address: old_address,
             ip_stack: old_ip_stack,
             type: old_type
           },
           struct: %Portal.Resource{address: address, ip_stack: ip_stack, type: type, id: id}
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

    # The cache will be updated by the policy authorization deletion handler.
    {:noreply, socket}
  end

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Resource{filters: old_filters, type: old_type},
           struct: %Portal.Resource{filters: filters, type: type} = resource
         },
         socket
       )
       when old_filters != filters and type != :static_device_pool and
              old_type != :static_device_pool do
    # Send regardless of cache state - if the Gateway has no policy_authorizations for this resource,
    # it will simply ignore the message.
    resource = Cache.Cacheable.to_cache(resource)

    case Resource.adapt_resource_for_version(resource, socket.assigns.session.version) do
      nil ->
        {:noreply, socket}

      adapted_resource ->
        push(socket, "resource_updated", Views.Resource.render(adapted_resource))
        {:noreply, socket}
    end
  end

  defp handle_change(%Change{}, socket), do: {:noreply, socket}

  # Shared eviction path for the CDC delete handler, the direct `:reject_access`
  # from `Portal.Queue`'s on_failed callback, and the authz durability timeout.
  # We look the authorization up by id and, if it was still active, push
  # `reject_access`; the client recovers by tripping ICMP "destination
  # prohibited" and requesting a fresh flow. Deletes of already-expired
  # authorizations (the `DeleteExpiredPolicyAuthorizations` reaper) are dropped
  # silently — connlib has already expired them locally.
  defp revoke_policy_authorization(socket, %Portal.PolicyAuthorization{
         id: id,
         initiating_device_id: client_id,
         resource_id: resource_id
       }) do
    case Cache.Gateway.delete(socket.assigns.cache, id, client_id, resource_id) do
      {:ok, expires_at_unix, cache} ->
        now_unix = DateTime.utc_now() |> DateTime.to_unix(:second)

        if expires_at_unix > now_unix do
          push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})
        end

        {:noreply, assign(socket, cache: cache)}

      :error ->
        {:noreply, socket}
    end
  end

  # Authz durability timer for fail-closed cleanup when the originating queue
  # loses state (crash, OOM, hard node death — anything that prevents
  # `on_failed` from firing reject_access on this gateway). Arms a per-authz
  # timer on receipt of allow; the timer fires `:authz_durability_timeout` if no
  # `:confirm_authz_durability` (queue's successful flush) or `:reject_access`
  # (queue's failure handler) arrives first. Same eviction path as
  # `:reject_access` once the timer fires.
  #
  # Each armed timer carries a `make_ref/0` generation token. `authz_durability`
  # stores `%{authz_id => {generation, timer_ref}}`. The handler matches the
  # incoming token against the current generation in pending; mismatch
  # (cancelled, replaced) is silently ignored. This avoids a race where the
  # timer fires just before a confirm arrives: `Process.cancel_timer/1` can
  # only stop a timer in the wheel — it can't remove an already-delivered
  # message from the mailbox.
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
        # channel disconnects and lets the gateway reconnect to create a new row.
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
      Process.send_after(
        self(),
        {:authz_durability_timeout, pa, generation},
        @authz_durability_timeout
      )

    pending = socket.assigns[:authz_durability] || %{}

    # If somehow we already had a timer for this authz_id (shouldn't happen
    # in normal flow, but guard against it), cancel the old one first.
    # Its message may still arrive — the generation check in the handler
    # ignores it.
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
        :ok = PG.join(socket.assigns.gateway.id)
        :ok = PG.join(socket.assigns.token_id)

        # Duplicate-connection resolution: watch our gateway id group and
        # disconnect if a newer connection joins it. Monitors die with the
        # scope, so this re-arms on every (re-)registration.
        {_ref, _members} = PG.monitor(socket.assigns.gateway.id)

        socket = assign(socket, :pg_scope_pid, new_pid)

        # Only enqueue + arm on the first successful registration; re-registrations
        # after a PG scope crash share the same channel and session row.
        if is_nil(current_pid) do
          Portal.Queue.enqueue(:gateway_session_queue, session_attrs(socket.assigns.session),
            metadata: %{timestamp: DateTime.utc_now()}
          )

          {:noreply, arm_session_durability_timer(socket)}
        else
          {:noreply, socket}
        end
    end
  end

  # Tracks gateway presence and monitors Presence tracker shard processes so we
  # can re-track if any crash. Monitoring the supervisor alone is insufficient
  # because individual shard crashes under :one_for_one don't kill the supervisor.
  defp track_presence(socket) do
    case Process.whereis(Portal.Presence) do
      nil ->
        Process.send_after(self(), :track_presence, 50)
        socket

      sup_pid ->
        gateway = socket.assigns.gateway
        session = socket.assigns.session

        session_meta = %{
          site_id: gateway.site_id,
          public_key: session.public_key,
          psk_base: gateway.psk_base,
          version: session.version,
          remote_ip: session.remote_ip,
          remote_ip_location_lat: session.remote_ip_location_lat,
          remote_ip_location_lon: session.remote_ip_location_lon
        }

        :ok = Presence.Gateways.connect(gateway, socket.assigns.token_id, session_meta)

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

  defp session_attrs(%Portal.GatewaySession{} = session) do
    session
    |> Map.from_struct()
    |> Map.drop([:__meta__, :account, :device, :gateway_token])
  end

  defp abnormal_exit?(:normal), do: false
  defp abnormal_exit?(:shutdown), do: false
  defp abnormal_exit?({:shutdown, _reason}), do: false
  defp abnormal_exit?(_reason), do: true

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def get_account_by_id!(id) do
      from(a in Account, where: a.id == ^id)
      |> Safe.unscoped(:replica)
      |> Safe.one!()
    end
  end
end
