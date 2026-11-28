defmodule PortalAPI.Gateway.Channel.Shared do
  use PortalAPI, :channel
  alias PortalAPI.Gateway.Views
  alias PortalAPI.Channel.Authorizations
  alias PortalAPI.Channel.Durability
  alias PortalAPI.Channel.Relays
  alias PortalAPI.Channel.Session
  alias __MODULE__.Database

  alias Portal.{
    Account,
    Cache,
    Device,
    PG,
    Changes.Change,
    PubSub,
    Relay.CandidateIPs,
    Resource,
    Presence,
    SchemaHelpers,
    Telemetry
  }

  require Logger

  # The interval at which the policy authorization cache is pruned.
  @prune_cache_every :timer.minutes(1)

  # A new salt keeps nodes from an earlier release from decoding this ref format.
  @reply_ref_salt "gateway_authorization_ref"
  @reply_ref_max_age_seconds 60

  # Relay credentials must be stable across reconnects, so they expire at fixed
  # weekly boundaries: Sunday 04:00 UTC (Saturday 8pm PST). Each boundary pushes
  # new credentials; the old ones stay valid for a short grace period after it.
  # Before the first boundary, Gateways keep the legacy expiry so the deploy
  # itself does not replace relay allocations.
  # TODO: Shorten this window when most gateways support this.
  @relay_credentials_first_rotation ~U[2026-11-29 04:00:00Z]
  @relay_credentials_rotate_every_seconds 7 * 24 * 60 * 60
  @relay_credentials_grace_seconds 60 * 60
  @legacy_relay_credentials_expire_at ~U[2038-01-01 00:00:00Z]

  @doc """
  Self-heal escape hatch. Pushes `reject_access` to a gateway's data plane
  for the given `(client_id, resource_id)` pair and clears the matching
  local cache entries.

  ## Not expected to be hit in production

  Every natural production code path that ends in `reject_access` on the
  gateway's data plane goes through `PortalAPI.Channel.Authorizations.revoke/2` first,
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
  has no DB row backing it. The gateway rejects the client's packets with
  a `no_authorization` p2p control event, upon which the client
  requests a fresh authorization through the normal portal path, closing
  the loop.

  This function is the manual version of that fail-closed signal. If the
  gateway's local cache ever desyncs from production state (a bug, a
  partial flush we didn't anticipate, an ops mistake), this lets us
  trigger the same fail-closed → no-authorization → re-authorize
  recovery without waiting for a queue to crash or for the authz
  durability timer to time out.

  Integration tests use it to exercise that recovery path end-to-end:
  the test asserts that even when the gateway is forced into a fail-closed
  state for a pair, the client correctly recovers and re-authorizes via
  the portal.

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

  @impl true
  def terminate(reason, socket), do: Session.terminate(reason, socket)

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def handle_info(:after_join, socket) do
    # Subscribe before reading any state so no change committed after the reads is missed.
    :ok = PubSub.Changes.subscribe(socket.assigns.gateway.account_id)

    socket =
      assign(socket,
        authorizations_cache: Cache.Gateway.hydrate(socket.assigns.gateway, device_pools: false),
        iceless_capable: false
      )

    Process.send_after(self(), :prune_cache, @prune_cache_every)
    schedule_relay_credentials_rotation(DateTime.utc_now())

    # Track gateway's presence
    gateway = socket.assigns.gateway

    Logger.debug("Tracking gateway presence",
      gateway_id: gateway.id,
      site_id: socket.assigns.site.id,
      account_id: gateway.account_id,
      token_id: socket.assigns.token_id
    )

    # Track gateway presence and monitor tracker shard processes for crash recovery
    socket = track_presence(socket)

    {:noreply, socket} = register(socket)

    # Subscribe before selecting relays so no relay presence change is missed.
    :ok = Presence.Relays.subscribe()
    relays = Relays.select(relay_owner(socket))

    account = Database.get_account_by_id!(socket.assigns.gateway.account_id)

    # Disabled between connect and the subscription above, so no change will tell us.
    if account.is_disabled do
      handle_info(:disconnect, socket)
    else
      socket = assign(socket, :account, account)

      init(socket, account, relays)

      :ok =
        PortalAPI.Sockets.notify_public_key_changed(
          socket.assigns.gateway,
          socket.assigns[:previous_public_key]
        )

      # Cache relay IDs and stamp secrets for tracking
      socket = Relays.cache(socket, relays)

      {:noreply, socket}
    end
  end

  def handle_info(:prune_cache, socket) do
    Process.send_after(self(), :prune_cache, @prune_cache_every)
    {:noreply, assign(socket, authorizations_cache: Cache.Authorizations.prune(socket.assigns.authorizations_cache))}
  end

  def handle_info({:rotate_relay_credentials, rotate_at}, socket) do
    schedule_relay_credentials_rotation(rotate_at)

    cached_relay_ids = socket.assigns[:cached_relay_ids] || MapSet.new()
    {:ok, online_relays} = Presence.Relays.all_connected_relays()
    relays = Enum.filter(online_relays, &MapSet.member?(cached_relay_ids, &1.id))

    if relays != [] do
      push(socket, "relays_presence", %{
        disconnected_ids: [],
        connected: Relays.render(relays, relay_owner(socket, rotate_at))
      })
    end

    {:noreply, socket}
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  def handle_info(%Change{} = change, socket) do
    Session.apply_change(socket, socket.assigns.gateway, change, &handle_change/2)
  end

  ####################################
  #### Reacting to relay presence ####
  ####################################

  # Relay presence changes are debounced: only the last one in a burst is checked.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "presences:relays" <> _},
        socket
      ) do
    Relays.schedule_check(socket)
  end

  def handle_info({:check_relay_presence, ref}, socket) do
    Relays.check(socket, ref, relay_owner(socket))
  end

  ###########################
  #### Connection setup #####
  ###########################

  def handle_info({:public_key_changed, :client, client_id, public_key}, socket) do
    if Portal.Version.supports_public_key_changed?(socket.assigns.gateway) do
      push(socket, "public_key_changed", %{client_id: client_id, public_key: public_key})
    end

    {:noreply, socket}
  end

  def handle_info({tag, %{type: :client, id: client_id}, candidates}, socket)
      when tag in [:ice_candidates, :invalidate_ice_candidates] do
    if Cache.Authorizations.has_client?(socket.assigns.authorizations_cache, client_id) do
      # The gateway binds channels on its own relays towards new candidates.
      if tag == :ice_candidates do
        CandidateIPs.report(
          socket.assigns[:cached_relay_ids] || MapSet.new(),
          socket.assigns.gateway.account_id,
          candidates
        )
      end

      push(socket, Atom.to_string(tag), %{client_id: client_id, candidates: candidates})
    else
      Telemetry.ice_candidates_dropped(:client, :unauthorized, candidate_count(candidates))
    end

    {:noreply, socket}
  end

  # Only a `/device/v1` connection of the same gateway can be a pool target. With no reply, the
  # initiator times out as it would for an offline target.
  def handle_info({:authorize, _from, %{resource: %Cache.Cacheable.Resource{type: :device_pool}}}, socket),
    do: {:noreply, socket}

  # The initiator is told only once the gateway echoes the ref, after it has the authorization.
  def handle_info({:authorize, {channel_pid, ref}, request}, socket) do
    initiator = request.initiator

    {use_iceless, socket} =
      Authorizations.accept(socket, socket.assigns.gateway, socket.assigns.account, request)

    ref_tuple =
      {:authorize, channel_pid, ref, request.resource.id, request.preshared_key,
       request.ice_credentials, use_iceless}

    push(socket, socket.assigns.channel_protocol.create_authorization_event(), %{
      ref: encode_ref(socket, ref_tuple),
      resource: Views.Resource.render(request.resource),
      gateway_ice_credentials: request.ice_credentials.receiver,
      client:
        Views.Client.render(
          struct(Device, initiator),
          initiator.public_key,
          request.preshared_key,
          initiator.user_agent
        ),
      client_ice_credentials: request.ice_credentials.initiator,
      expires_at: DateTime.to_unix(request.expires_at, :second),
      subject: request.subject,
      use_iceless: use_iceless,
      flow_logs_ingest_token: request.responder_token
    })

    {:noreply, socket}
  end

  # DEPRECATED IN 1.4
  def handle_info({:allow_access, {channel_pid, socket_ref}, attrs}, socket) do
    %{
      client_id: client_id,
      client_ipv4: client_ipv4,
      client_ipv6: client_ipv6,
      resource: %Cache.Cacheable.Resource{} = resource,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload
    } = attrs

    case Resource.adapt_resource_for_version(resource, socket.assigns.gateway.last_seen_version) do
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

        {:noreply, accept_legacy(socket, client_id, resource, attrs)}
    end
  end

  # DEPRECATED IN 1.4
  def handle_info({:request_connection, {channel_pid, socket_ref}, attrs}, socket) do
    %{
      client: client,
      resource: %Cache.Cacheable.Resource{} = resource,
      authorization_expires_at: authorization_expires_at
    } = attrs

    case Resource.adapt_resource_for_version(resource, socket.assigns.gateway.last_seen_version) do
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

        {:noreply, accept_legacy(socket, client.id, resource, attrs)}
    end
  end

  # Direct revocation from `Portal.Queue`'s on_failed path — a policy
  # authorization that we already announced via `:allow_access` /
  # `:authorize` failed to persist. We reuse the same eviction path the
  # CDC delete handler uses: drop the cached authorization and push
  # `reject_access` so connlib tears down the flow.
  def handle_info({:reject_access, %Portal.PolicyAuthorization{} = policy_authorization}, socket) do
    socket = Durability.cancel_authorization(socket, policy_authorization.id)
    Authorizations.revoke(socket, policy_authorization)
  end

  # Queue confirms a policy_authorization was durably persisted — cancel the
  # corresponding authz durability timer so the receiver doesn't revoke a valid
  # authorization.
  def handle_info({:confirm_authz_durability, authz_id}, socket) do
    {:noreply, Durability.cancel_authorization(socket, authz_id)}
  end

  def handle_info({:confirm_session_durability, session_ref}, socket) do
    {:noreply, Durability.cancel_session(socket, session_ref)}
  end

  def handle_info({:authz_durability_timeout, %Portal.PolicyAuthorization{} = pa, generation}, socket) do
    Durability.authorization_timeout(socket, pa, generation)
  end

  def handle_info({:session_durability_timeout, session_ref}, socket) do
    Durability.session_timeout(socket, session_ref)
  end

  # Handler for the public `revoke_pair_access/3` self-heal helper.
  def handle_info({:revoke_pair_access, client_id, resource_id}, socket) do
    push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})

    key = {Ecto.UUID.dump!(client_id), Ecto.UUID.dump!(resource_id)}

    # Cancel any pending authz durability timer for the cached authz of this pair
    # so it doesn't fire later, find the cache empty, and log a spurious warning.
    socket =
      case Map.get(socket.assigns.authorizations_cache, key) do
        {pa_id_bytes, _exp} ->
          Durability.cancel_authorization(socket, Ecto.UUID.load!(pa_id_bytes))

        nil ->
          socket
      end

    cache = Map.delete(socket.assigns.authorizations_cache, key)
    {:noreply, assign(socket, authorizations_cache: cache)}
  end

  def handle_info(:disconnect, socket), do: Session.disconnect(socket)

  # Flush-failure disconnects are PG-delivered by device id but target one
  # session; a mismatched ref belongs to a predecessor channel and falls
  # through to the catch-all.
  def handle_info({:disconnect, session_ref}, socket)
      when session_ref == socket.assigns.session_ref do
    handle_info(:disconnect, socket)
  end

  # Another channel joined our gateway id group: a duplicate connection raced
  # past the connect-time check. First wins — we were here first, so tell the
  # newcomers to close. Two simultaneous cross-node joins can each observe the
  # other and boot each other, but gateway reconnect backoff jitter settles that
  # within a round or two.
  def handle_info({_ref, :join, gateway_id, pids}, socket)
      when gateway_id == socket.assigns.gateway.id do
    for pid <- pids, pid != self() do
      Logger.info("Disconnecting duplicate gateway connection",
        gateway_id: socket.assigns.gateway.id
      )

      send(pid, :duplicate_connection)
    end

    {:noreply, socket}
  end

  # No "token_expired" push: the gateway exits on it, but a duplicate must reconnect.
  def handle_info(:duplicate_connection, socket) do
    Session.close_transport(socket)
  end

  def handle_info({_ref, :leave, gateway_id, _pids}, socket)
      when gateway_id == socket.assigns.gateway.id do
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    case Session.monitored(socket, pid) do
      :pg_scope -> register(socket)
      :presence -> {:noreply, track_presence(socket)}
      nil -> {:noreply, socket}
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
  def handle_in("authorization_created", %{"ref" => signed_ref}, socket) do
    case decode_ref(socket, signed_ref) do
      {:ok,
       {:authorize, channel_pid, ref, rid_bytes, preshared_key, ice_credentials, use_iceless}} ->
        Authorizations.reply(channel_pid, ref, socket.assigns.gateway, %{
          resource_id: Ecto.UUID.load!(rid_bytes),
          site_id: socket.assigns.site.id,
          preshared_key: preshared_key,
          ice_credentials: ice_credentials,
          use_iceless: use_iceless
        })

        {:reply, :ok, socket}

      _other ->
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

      _other ->
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
    deliver_to_clients(socket, client_ids, :ice_candidates, candidates)
  end

  def handle_in(
        "broadcast_invalidated_ice_candidates",
        %{"candidates" => candidates, "client_ids" => client_ids},
        socket
      ) do
    deliver_to_clients(socket, client_ids, :invalidate_ice_candidates, candidates)
  end

  def handle_in("set_snownet_capabilities", payload, socket) when is_map(payload) do
    {:noreply, assign(socket, iceless_capable: payload["iceless"] == true)}
  end

  def handle_in("no_relays", payload, socket) do
    Relays.no_relays(socket, payload, relay_owner(socket))
  end

  # Catch-all for unknown messages
  def handle_in(message, payload, socket) do
    unknown_message(message, payload, socket)
  end

  @doc false
  def unknown_message(message, payload, socket) do
    Logger.error("Unknown gateway message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  # `initiator_iceless_capable` is always false on the deprecated 1.4 paths:
  # those clients predate the capability handshake, so they can never go ICE-less.
  defp accept_legacy(socket, client_id, resource, attrs) do
    {_use_iceless, socket} =
      Authorizations.accept(socket, socket.assigns.gateway, socket.assigns.account, %{
        initiator: %{id: client_id},
        resource: resource,
        policy_authorization_id: attrs.policy_authorization_id,
        expires_at: attrs.authorization_expires_at,
        policy_authorization: attrs[:policy_authorization],
        initiator_iceless_capable: false
      })

    socket
  end

  defp encode_ref(socket, tuple) do
    ref =
      {socket.assigns.gateway.id, tuple}
      |> :erlang.term_to_binary()
      |> Base.url_encode64()

    key_base = socket.endpoint.config(:secret_key_base)
    Plug.Crypto.sign(key_base, @reply_ref_salt, ref)
  end

  defp decode_ref(socket, signed_ref) do
    key_base = socket.endpoint.config(:secret_key_base)
    gateway_id = socket.assigns.gateway.id

    with {:ok, ref} <-
           Plug.Crypto.verify(key_base, @reply_ref_salt, signed_ref,
             max_age: @reply_ref_max_age_seconds
           ),
         {:ok, binary} <- Base.url_decode64(ref),
         {^gateway_id, tuple} <- Plug.Crypto.non_executable_binary_to_term(binary, [:safe]) do
      {:ok, tuple}
    else
      _other -> {:error, :invalid_ref}
    end
  end

  defp relay_owner(socket, now \\ DateTime.utc_now()) do
    %{
      device: socket.assigns.gateway,
      location:
        {socket.assigns.gateway.last_seen_remote_ip_location_lat,
         socket.assigns.gateway.last_seen_remote_ip_location_lon},
      expires_at: relay_credentials_expire_at(now)
    }
  end

  defp init(socket, account, relays) do
    push(socket, "init", %{
      flow_logs: flow_logs_config(),
      authorizations: Views.PolicyAuthorization.render_many(socket.assigns.authorizations_cache),
      account_slug: account.slug,
      interface: Views.Interface.render(socket.assigns.gateway),
      relays:
        Relays.render(relays, relay_owner(socket)),
      # These aren't used but needed for API compatibility
      config: %{
        ipv4_masquerade_enabled: true,
        ipv6_masquerade_enabled: true
      }
    })
  end

  defp flow_logs_config do
    flow_logs_config(Portal.Config.fetch_env!(:portal, :flow_logs_api_url))
  end

  # Connlib requires a string `api_url` and reads an interval of 0 as uploads disabled.
  defp flow_logs_config(nil), do: %{api_url: "", upload_interval_secs: 0, upload_batch_size: 0}

  defp flow_logs_config(api_url) do
    %{
      api_url: api_url,
      upload_interval_secs: Portal.Config.fetch_env!(:portal, :flow_logs_upload_interval_secs),
      upload_batch_size: Portal.Config.fetch_env!(:portal, :flow_logs_upload_batch_size)
    }
  end

  defp reinitialize_gateway(socket) do
    relays = Relays.select(relay_owner(socket))
    socket = Relays.cache(socket, relays)
    account = Database.get_account_by_id!(socket.assigns.gateway.account_id)

    init(socket, account, relays)
    socket
  end

  ##########################################
  #### Handling changes from the domain ####
  ##########################################

  # ACCOUNTS

  # A disabled account arrives as a delete.
  # Resend init when config changes so that new slug may be applied
  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Account{slug: old_slug},
           struct: %Portal.Account{slug: slug} = account
         },
         socket
       ) do
    account = SchemaHelpers.merge_broadcast(socket.assigns.account, account)
    socket = assign(socket, :account, account)

    if old_slug != slug do
      relays = Relays.select(relay_owner(socket))
      init(socket, account, relays)
    end

    {:noreply, socket}
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
    gateway = Device.merge_broadcast(current_gateway, gateway)
    socket = assign(socket, :gateway, gateway)

    socket =
      if old_gateway.ipv4 != gateway.ipv4 or old_gateway.ipv6 != gateway.ipv6 do
        reinitialize_gateway(socket)
      else
        socket
      end

    {:noreply, socket}
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
    pairs = Cache.Authorizations.all_pairs_for_resource(socket.assigns.authorizations_cache, id)

    for {client_id, resource_id} <- pairs do
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
       when old_filters != filters and type != :device_pool and
              old_type != :device_pool do
    # Send regardless of cache state - if the Gateway has no policy_authorizations for this resource,
    # it will simply ignore the message.
    resource = Cache.Cacheable.to_cache(resource)

    case Resource.adapt_resource_for_version(resource, socket.assigns.gateway.last_seen_version) do
      nil ->
        {:noreply, socket}

      adapted_resource ->
        push(socket, "resource_updated", Views.Resource.render(adapted_resource))
        {:noreply, socket}
    end
  end

  defp handle_change(%Change{}, socket), do: {:noreply, socket}

  defp register(socket) do
    case Session.monitor_pg_scope(socket) do
      {:joined, socket, previous_pid} ->
        :ok = PG.join(socket.assigns.gateway.id)
        :ok = PG.join(socket.assigns.token_id)

        # Duplicate-connection resolution: watch our gateway id group and
        # disconnect if a newer connection joins it. Monitors die with the
        # scope, so this re-arms on every (re-)registration.
        {_ref, _members} = PG.monitor(socket.assigns.gateway.id)

        register_session(socket, previous_pid)

      result ->
        result
    end
  end

  # Only enqueue + arm on the first successful registration; re-registrations
  # after a PG scope crash share the same channel and session row.
  defp register_session(socket, nil) do
    Portal.Queue.enqueue(
      :gateway_session_queue,
      session_attrs(socket.assigns.gateway, socket.assigns.session_ref),
      metadata: %{timestamp: DateTime.utc_now()}
    )

    {:noreply, Durability.arm_session(socket)}
  end

  # A token deleted while the scope was down missed its PG disconnect.
  defp register_session(socket, _current_pid) do
    if Database.token_exists?(socket.assigns.gateway.account_id, socket.assigns.token_id) do
      {:noreply, socket}
    else
      handle_info(:disconnect, socket)
    end
  end

  defp track_presence(socket) do
    range = Portal.Version.legacy_proto_range(:gateway, socket.assigns.gateway.last_seen_version)

    Session.track_presence(socket, socket.assigns.gateway, socket.assigns.token_id, %{
      site_ids: [socket.assigns.site.id],
      capabilities: [],
      proto_min: range && range.min,
      proto_max: range && range.max
    })
  end

  @doc false
  def session_attrs(%Portal.Device{} = gateway, session_ref) do
    %{
      session_ref: session_ref,
      account_id: gateway.account_id,
      device_id: gateway.id,
      token_id: gateway.token_id,
      public_key: gateway.public_key,
      user_agent: gateway.last_seen_user_agent,
      remote_ip: gateway.last_seen_remote_ip,
      remote_ip_location_region: gateway.last_seen_remote_ip_location_region,
      remote_ip_location_city: gateway.last_seen_remote_ip_location_city,
      remote_ip_location_lat: gateway.last_seen_remote_ip_location_lat,
      remote_ip_location_lon: gateway.last_seen_remote_ip_location_lon,
      version: gateway.last_seen_version
    }
  end

  defp deliver_to_clients(socket, client_ids, tag, candidates) when is_list(client_ids) do
    candidates = PortalAPI.Sockets.limit_ice_candidates(candidates, socket.assigns.gateway)

    if candidates != [] do
      client_ids
      |> Enum.uniq()
      |> Enum.each(&deliver_to_client(socket, &1, tag, candidates))
    end

    {:noreply, socket}
  end

  defp deliver_to_clients(socket, _client_ids, _tag, _candidates), do: {:noreply, socket}

  defp deliver_to_client(socket, client_id, tag, candidates) do
    if Cache.Authorizations.has_client?(socket.assigns.authorizations_cache, client_id) do
      PG.deliver(client_id, {tag, %{type: :gateway, id: socket.assigns.gateway.id}, candidates})
    else
      Telemetry.ice_candidates_dropped(:gateway, :unauthorized, length(candidates))
    end
  end

  defp candidate_count(candidates) when is_list(candidates), do: length(candidates)
  defp candidate_count(_candidates), do: 0

  defp relay_credentials_expire_at(now) do
    if DateTime.before?(now, @relay_credentials_first_rotation) do
      @legacy_relay_credentials_expire_at
    else
      now
      |> next_relay_credentials_rotation()
      |> DateTime.add(@relay_credentials_grace_seconds, :second)
    end
  end

  defp next_relay_credentials_rotation(now) do
    if DateTime.before?(now, @relay_credentials_first_rotation) do
      @relay_credentials_first_rotation
    else
      elapsed = DateTime.diff(now, @relay_credentials_first_rotation, :second)
      windows = div(elapsed, @relay_credentials_rotate_every_seconds) + 1

      DateTime.add(
        @relay_credentials_first_rotation,
        windows * @relay_credentials_rotate_every_seconds,
        :second
      )
    end
  end

  defp schedule_relay_credentials_rotation(now) do
    rotate_at = next_relay_credentials_rotation(now)
    delay = DateTime.diff(rotate_at, now, :millisecond)
    Process.send_after(self(), {:rotate_relay_credentials, rotate_at}, delay)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def get_account_by_id!(id) do
      from(a in Account, where: a.id == ^id)
      |> Safe.unscoped()
      |> Safe.one!()
    end

    def token_exists?(account_id, id) do
      from(t in Portal.DeviceToken, where: t.account_id == ^account_id, where: t.id == ^id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end
