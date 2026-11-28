defmodule PortalAPI.Client.Channel.Shared do
  use PortalAPI, :channel
  alias Portal.Authentication.Credential
  alias PortalAPI.Client.Views
  alias PortalAPI.Channel.Authorizations
  alias PortalAPI.Channel.Durability
  alias PortalAPI.Channel.Protocol
  alias PortalAPI.Channel.Relays
  alias PortalAPI.Channel.Session

  alias Portal.{
    Cache,
    Device,
    Devices,
    FlowLogToken,
    PG,
    Changes.Change,
    PubSub,
    Presence,
    Routing,
    SchemaHelpers,
    Authentication
  }

  alias Portal.Repo.Batch
  alias __MODULE__.Database
  require Logger

  # For time-based policy conditions, we need to determine whether we still have access
  # If not, we need to send resource_deleted so that if it's added back later, the client's
  # connlib state will be cleaned up so it can request a new connection.
  @recompute_authorized_resources_every :timer.minutes(1)

  @posture_provider_schemas [
    Portal.Intune.PostureProvider,
    Portal.Iru.PostureProvider,
    Portal.Defender.PostureProvider,
    Portal.Santa.PostureProvider,
    Portal.SentinelOne.PostureProvider,
    Portal.Sophos.PostureProvider
  ]

  # The interval at which the inbound policy_authorizations cache is pruned.
  @prune_authorizations_cache_every :timer.minutes(1)

  # A device lookup that the asking client may not have answers after this long, whether or
  # not anything is behind the name or address. Devices it may reach answer straight away.
  @device_lookup_constant_time 500

  # How long, in seconds, connlib and the resolvers behind it may cache what a PTR query in
  # the device domain lists.
  @device_domain_browse_ttl 30

  # The most PTR records a DNS message holds, even with compressed one-character labels.
  @device_domain_browse_limit 4_096

  @max_ice_candidate_gateways 64

  # Admin-only data, so a receiving client's ingest token does not include it.
  @admin_only_initiator_claims ~w[initiator_actor_email initiator_auth_provider_id
                                  initiator_device_serial initiator_device_uuid
                                  initiator_device_identifier_for_vendor
                                  initiator_device_firebase_installation_id]

  @doc false
  def policy_authorization_queue_opts do
    [
      name: Portal.Queue.name(:policy_authorization_queue),
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

  @impl true
  def terminate(reason, socket), do: Session.terminate(reason, socket)

  @impl true
  # Called immediately after the client joins the channel
  def handle_info(:after_join, socket) do
    # Subscribe before reading any state so no change committed after the reads is missed.
    :ok = PubSub.Changes.subscribe(socket.assigns.client.account_id)

    case Database.fetch_device_with_actor_and_account(socket.assigns.client) do
      nil ->
        {:stop, :shutdown, socket}

      %Device{account: account, actor: actor} when account.is_disabled or actor.is_disabled ->
        handle_info(:disconnect, socket)

      %Device{} = device ->
        socket
        |> refresh_connect_state(device)
        |> hydrate_and_init()
    end
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  def handle_info(%Change{} = change, socket) do
    Session.apply_change(socket, socket.assigns.client, change, &handle_change/2)
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

    socket = expire_attestation(socket)

    {:ok, added_resources, removed_ids, cache} =
      Cache.Client.recompute_connectable_resources(
        socket.assigns.cache,
        socket.assigns.client,
        socket.assigns.subject
      )

    for resource_id <- removed_ids do
      Protocol.push(socket, "resource_deleted", resource_id)
    end

    for resource <- added_resources do
      Protocol.push(
        socket,
        "resource_created_or_updated",
        Views.Resource.render(resource, socket.assigns.client, protocol_version(socket))
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
       authorizations_cache:
         Cache.Authorizations.prune(socket.assigns.authorizations_cache),
       outbound_authorizations_cache:
         Cache.Authorizations.prune(socket.assigns.outbound_authorizations_cache)
     )}
  end

  ####################################
  #### Reacting to relay presence ####
  ####################################

  # Relay presence changes are debounced: only the last one in a burst is checked.
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "presences:relays" <> _},
        socket
      ) do
    Relays.schedule_check(socket)
  end

  def handle_info({:check_relay_presence, ref}, socket) do
    Relays.check(socket, ref, relay_owner(socket))
  end

  #############################################################
  ##### Forwarding replies from the gateway to the client #####
  #############################################################

  def handle_info({tag, %{type: :gateway, id: gateway_id}, candidates}, socket)
      when tag in [:ice_candidates, :invalidate_ice_candidates] do
    Protocol.push(socket, Atom.to_string(tag), %{gateway_id: gateway_id, candidates: candidates})
    {:noreply, socket}
  end

  def handle_info({:ice_candidates, %{type: :client, id: client_id}, candidates}, socket) do
    Protocol.push(socket, "client_ice_candidates", %{client_id: client_id, candidates: candidates})
    {:noreply, socket}
  end

  def handle_info({:invalidate_ice_candidates, %{type: :client, id: client_id}, candidates}, socket) do
    Protocol.push(socket, "invalidate_client_ice_candidates", %{
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

  # A gateway replies once it confirms; a client replies at once. A gateway reply counts only
  # for the pending request and the gateway it was sent to.
  def handle_info({:authorized, ref, reply}, socket) do
    if Map.has_key?(socket.assigns.pending_authorizations, ref) do
      release_device_access(socket, ref, reply.use_iceless, reply.name, reply.slug)
    else
      release_gateway_authorization(socket, reply.resource_id, ref, reply)
    end
  end

  # `generation` rejects a stale timeout whose entry was already replaced by a
  # newer request_authorization for the same resource_id (its message may already be queued).
  def handle_info({:authorization_creation_timeout, resource_id, generation}, socket) do
    case Map.get(socket.assigns.pending_authorizations, resource_id) do
      {^generation, _timer_ref, _initiator_token, address, _gateway_id} ->
        push_authorization_creation_failed(socket, resource_id, :offline, address)

        {:noreply,
         assign(
           socket,
           :pending_authorizations,
           Map.delete(socket.assigns.pending_authorizations, resource_id)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:authorization_creation_timeout, ref}, socket) do
    case Map.pop(socket.assigns.pending_authorizations, ref) do
      {nil, _} ->
        {:noreply, socket}

      # Client-to-client: the target's channel never acked that it pushed the
      # authorization to its data plane (e.g. it disconnected in the window).
      {%{deny_payload: deny_payload}, remaining} ->
        Protocol.push(socket, "client_device_access_denied", deny_payload)
        {:noreply, assign(socket, :pending_authorizations, remaining)}
    end
  end

  # The resource is rendered for this client's own protocol version.
  def handle_info({:authorize, {initiator_pid, ref}, request}, socket) do
    initiator = request.initiator
    client = socket.assigns.client

    {use_iceless, socket} =
      Authorizations.accept(socket, client, socket.assigns.subject.account, request)

    payload =
      %{
        client_id: initiator.id,
        client_name: initiator.name,
        client_slug: initiator.slug,
        client_public_key: initiator.public_key,
        client_ipv4: initiator.ipv4,
        client_ipv6: initiator.ipv6,
        preshared_key: request.preshared_key,
        local_ice_credentials: request.ice_credentials.receiver,
        remote_ice_credentials: request.ice_credentials.initiator,
        ice_role: :controlled,
        resource: Views.Resource.render(request.resource, client, protocol_version(socket)),
        flow_logs_ingest_token: request.responder_token,
        use_iceless: use_iceless
      }
      |> maybe_put_expires_at(request.expires_at)

    Protocol.push(socket, "client_device_access_authorized", payload)

    # The initiator is told only after the push, so its ICE candidates, which come over this
    # socket too, cannot reach this client before the authorization.
    Authorizations.reply(initiator_pid, ref, client, %{
      resource_id: Ecto.UUID.load!(request.resource.id),
      site_id: nil,
      preshared_key: request.preshared_key,
      ice_credentials: request.ice_credentials,
      use_iceless: use_iceless
    })

    {:noreply, socket}
  end

  def handle_info({:public_key_changed, type, device_id, public_key}, socket) do
    if Portal.Version.supports_public_key_changed?(socket.assigns.client) do
      payload =
        case type do
          :client -> %{client_id: device_id, public_key: public_key}
          :gateway -> %{gateway_id: device_id, public_key: public_key}
        end

      Protocol.push(socket, "public_key_changed", payload)
    end

    {:noreply, socket}
  end

  # Delivered to the receiver (peer client, in the client-to-client case) via
  # `Portal.PG` when a policy_authorization fails to persist after the receiver
  # was already told it could accept the connection. Mirrors the gateway's
  # reject_access handler: drop the cached authorization and push `reject_access`
  # via the same eviction path used for CDC deletes.
  def handle_info({:reject_access, %Portal.PolicyAuthorization{} = policy_authorization}, socket) do
    socket = Durability.cancel_authorization(socket, policy_authorization.id)
    Authorizations.revoke(socket, policy_authorization)
  end

  # Sent to the initiator when its policy_authorization failed to persist, so no CDC delete comes.
  def handle_info({:outbound_authorization_failed, %Portal.PolicyAuthorization{} = pa}, socket) do
    {:noreply, delete_outbound_authorization(socket, pa)}
  end

  # Queue confirms a c2c policy_authorization was durably persisted; cancel
  # the authz durability timer so the timer doesn't fire and revoke.
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

  def handle_info(:disconnect, socket), do: Session.disconnect(socket)

  # Flush-failure disconnects are PG-delivered by device id but target one
  # session; a mismatched ref belongs to a predecessor channel and falls
  # through to the catch-all.
  def handle_info({:disconnect, session_ref}, socket)
      when session_ref == socket.assigns.session_ref do
    handle_info(:disconnect, socket)
  end

  # A CA revoked a certificate. The session is only cut if it is the one this
  # connection actually presented: the device columns the sync job matched on
  # record the last certificate a device ever showed, so a device that attested
  # once and has since been connecting without a certificate would otherwise be
  # dropped over a certificate it is not using.
  #
  # Its authorizations go too. The tunnel is being torn down either way, so the
  # client has to re-authorize on its next connect regardless, and nothing else
  # clears them when a channel stops.
  #
  # A reason of its own rather than "token_expired": the token is fine, and a
  # client that knows the difference can say so instead of reporting a sign-in
  # problem. A client that does not recognize the reason ignores the payload and
  # still sees the socket close, so it is cut either way.
  def handle_info({:certificate_revoked, issuer, serial}, socket) do
    if socket.assigns[:attestation] == %{issuer: issuer, serial: serial} do
      Logger.info("Disconnecting device: its certificate was revoked",
        account_id: socket.assigns.client.account_id,
        device_id: socket.assigns.client.id,
        cert_serial: serial
      )

      Database.delete_policy_authorizations(socket.assigns.client)
      Protocol.push(socket, "disconnect", %{reason: "certificate_revoked"})
      Session.close_transport(socket)
    else
      {:noreply, socket}
    end
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

  def handle_info({:device_domain_resolution_failed, domain, reason}, socket) do
    Protocol.push(socket, "device_domain_resolution_failed", %{domain: domain, reason: reason})

    {:noreply, socket}
  end

  def handle_info({:device_domain_browse_failed, domain}, socket) do
    Protocol.push(socket, "device_domain_browse_failed", %{domain: domain, reason: :not_found})

    {:noreply, socket}
  end

  def handle_info({:device_access_denied, payload, reason}, socket) do
    push_device_access_denied(socket, payload, reason)
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
          "policy_authorizations_resource_id_fkey" => {:composite, :resource_id, Portal.Resource},
          "policy_authorizations_token_id_fkey" => {:composite, :token_id, Portal.DeviceToken},
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

        PG.deliver(
          attrs.initiating_device_id,
          {:outbound_authorization_failed, policy_authorization}
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

  # A gateway serves a resource only from the resource's site.
  defp fetch_resource_gateway(account_id, gateway_id, %{site: %{id: site_id}}) do
    Presence.Devices.fetch_gateway(account_id, gateway_id, Ecto.UUID.load!(site_id))
  end

  defp fetch_resource_gateway(_account_id, _gateway_id, _resource), do: {:error, :offline}

  defp put_site_id(payload, site_id, client) do
    key =
      if Portal.Version.client_supports_sites_payload?(client) do
        :site_id
      else
        :gateway_group_id
      end

    Map.put(payload, key, site_id)
  end

  defp authorization_created_event(socket) do
    socket.assigns.channel_protocol.authorization_created_event()
  end

  defp authorization_creation_failed_event(socket) do
    socket.assigns.channel_protocol.authorization_creation_failed_event()
  end

  ####################################
  ##### Client-initiated actions #####
  ####################################

  # This message is sent by the client to request authorization for a resource served by a
  # gateway or, on the v2 protocol, a device pool member.
  #
  # For gateway-backed resources, `connected_gateway_ids` indicates that the client is already
  # connected to some of the gateways, so the gateway can be reused by multiplexing the connection.
  #
  # For device pool resources, the payload also carries `ipv4` or `ipv6` of the target
  # member device.
  def handle_in(
        "request_authorization",
        %{"resource_id" => resource_id} = payload,
        socket
      ) do
    case Cache.Client.authorize_resource(
           socket.assigns.cache,
           socket.assigns.client,
           resource_id,
           socket.assigns.subject
         ) do
      {:ok, %Cache.Cacheable.Resource{type: :device_pool} = resource, membership_id, policy_id,
       expires_at} ->
        handle_request_pool_authorization(
          resource_id,
          resource,
          membership_id,
          policy_id,
          expires_at,
          payload,
          socket
        )

      result ->
        handle_authorized_gateway_resource(
          result,
          resource_id,
          Map.get(payload, "connected_gateway_ids", []),
          socket
        )
    end
  end

  # Connlib intercepts DNS queries for `<slug>.firezone.network`. A name the client may reach
  # resolves straight away. Every other name answers after the same delay, so the account's
  # devices cannot be listed by guessing names: `not_a_device` if it labels a pool the client
  # may use, `not_found` otherwise.
  def handle_in("resolve_device_domain", %{"domain" => domain}, socket) when is_binary(domain) do
    started_at = System.monotonic_time(:millisecond)

    case resolve_device_domain(domain, socket) do
      {:ok, %Portal.Device{} = device} ->
        Protocol.push(socket, "device_domain_resolved", %{
          domain: domain,
          ipv4: to_string(:inet.ntoa(device.ipv4.address)),
          ipv6: to_string(:inet.ntoa(device.ipv6.address))
        })

      {:error, reason} ->
        schedule_after_constant_time(
          started_at,
          {:device_domain_resolution_failed, domain, reason}
        )
    end

    {:noreply, socket}
  end

  # Connlib forwards PTR queries for `firezone.network` and every name under it. The domain
  # itself lists the labels of the pools the client may use, and such a label the devices
  # in those pools that resolve for the client, most recently seen first. A label that only
  # names a device the client may reach lists nothing. A listing holds at most
  # `@device_domain_browse_limit` names and `total` counts those it would hold without that
  # cap. Every other name answers `not_found` after the same delay as
  # `resolve_device_domain`, so pool names cannot be discovered by guessing either.
  def handle_in("browse_device_domain", %{"domain" => domain}, socket) when is_binary(domain) do
    started_at = System.monotonic_time(:millisecond)

    case browse_device_domain(domain, socket) do
      {:ok, labels, total} ->
        Protocol.push(socket, "device_domain_browsed", %{
          domain: domain,
          names: Enum.map(labels, &Portal.Device.fqdn_for_slug/1),
          ttl: @device_domain_browse_ttl,
          total: total
        })

      {:error, :not_found} ->
        schedule_after_constant_time(started_at, {:device_domain_browse_failed, domain})
    end

    {:noreply, socket}
  end

  # Connlib matched a packet against its resources and asks for access through them, most
  # preferred first. A packet for a device in the tunnel range names the pools whose filters
  # permit it and carries the address; the portal grants the first pool that holds the
  # device. Any other packet names the one resource connlib routes it through.
  def handle_in("request_access", payload, socket) do
    if protocol_version(socket) >= 3 do
      handle_request_access(payload, socket)
    else
      {:noreply, socket}
    end
  end

  # Some clients send these sporadically by accident since any packet with a destination in
  # 100.64.0.0/10 will trigger it in certain older clients. Message was introduced for the PoC
  # of client-to-client, but was replaced with the standard create-authorization message. We no-op it.
  def handle_in("request_device_access", _payload, socket) do
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
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateway} <-
           Routing.select_receiver(resource, initiator(socket), connected_gateway_ids) do
      reply =
        {:ok,
         %{
           resource_id: resource_id,
           site_id: Ecto.UUID.load!(resource.site.id),
           gateway_id: gateway.id,
           gateway_remote_ip: gateway.last_seen_remote_ip
         }}

      {:reply, reply, socket}
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, :offline} ->
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
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateway} <-
           fetch_resource_gateway(socket.assigns.subject.account.id, gateway_id, resource) do
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
           authorization_expires_at: expires_at,
           client_payload: payload
         }}

      policy_authorization = struct(Portal.PolicyAuthorization, attrs)

      case Portal.Queue.enqueue(Portal.Queue.name(:policy_authorization_queue), attrs,
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
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateway} <-
           fetch_resource_gateway(socket.assigns.subject.account.id, gateway_id, resource) do
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
               socket.assigns.client.public_key,
               client_payload,
               preshared_key
             ),
           resource: resource,
           policy_authorization_id: policy_authorization_id,
           authorization_expires_at: expires_at
         }}

      policy_authorization = struct(Portal.PolicyAuthorization, attrs)

      case Portal.Queue.enqueue(Portal.Queue.name(:policy_authorization_queue), attrs,
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

    end
  end

  def handle_in(
        "new_gateway_ice_candidates",
        %{"candidates" => candidates, "gateway_id" => gateway_id},
        socket
      ) do
    deliver_to_gateways(socket, [gateway_id], :ice_candidates, candidates)
  end

  def handle_in(
        "invalidate_gateway_ice_candidates",
        %{"candidates" => candidates, "gateway_id" => gateway_id},
        socket
      ) do
    deliver_to_gateways(socket, [gateway_id], :invalidate_ice_candidates, candidates)
  end

  def handle_in(
        "new_client_ice_candidates",
        %{"candidates" => candidates, "client_id" => target_client_id},
        socket
      ) do
    deliver_to_client(socket, target_client_id, :ice_candidates, candidates)
    {:noreply, socket}
  end

  def handle_in(
        "invalidate_client_ice_candidates",
        %{"candidates" => candidates, "client_id" => target_client_id},
        socket
      ) do
    case deliver_to_client(
           socket,
           target_client_id,
           :invalidate_ice_candidates,
           candidates
         ) do
      :ok ->
        {:noreply, socket}

      {:error, :not_found} ->
        Protocol.push(socket, "client_ice_candidate_error", %{
          client_id: target_client_id,
          reason: :offline
        })

        {:noreply, socket}
    end
  end

  # The client pushes it's ICE candidates list and the list of gateways that need to receive it
  def handle_in(
        "broadcast_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    deliver_to_gateways(socket, gateway_ids, :ice_candidates, candidates)
  end

  def handle_in(
        "broadcast_invalidated_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    deliver_to_gateways(socket, gateway_ids, :invalidate_ice_candidates, candidates)
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
    Logger.error("Unknown client message",
      message: message,
      payload: payload,
      subject: Map.get(socket.assigns, :subject),
      client: Map.get(socket.assigns, :client)
    )

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  # Reject peer connections when:
  #   - the target client predates `client_device_access_authorized` / `_denied`
  #     handling (older clients silently drop the message, leaving the initiator
  #     stuck waiting), or
  #   - initiator and target are on different minor versions — snownet's wire
  #     format may change on a minor cadence, so cross-minor pairs are unsafe.
  # A `/device/v1` target always handles `authorize_peer`, and a gateway's version is not a client's.
  defp check_peer_compatibility(target_meta, socket) do
    target_user_agent = Map.get(target_meta, :user_agent)
    target_version = Map.get(target_meta, :version)

    if (Map.get(target_meta, :device_v1, false) or
          Portal.Version.supports_device_access?(target_user_agent, target_version)) and
         Portal.Version.compatible?(proto_range(socket), Portal.Version.proto_range_from_meta(target_meta)) do
      :ok
    else
      {:error, :version_mismatch}
    end
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

  defp address_fields(nil), do: %{}
  defp address_fields({:ipv4, tuple}), do: %{ipv4: to_string(:inet.ntoa(tuple))}
  defp address_fields({:ipv6, tuple}), do: %{ipv6: to_string(:inet.ntoa(tuple))}

  defp fetch_target_device(target, socket) do
    with {:ok, %Portal.Device{} = device} <-
           Database.get_device_by_address(target, socket.assigns.subject) do
      if device.id == socket.assigns.client.id do
        {:error, :forbidden}
      else
        {:ok, device}
      end
    end
  end

  defp fetch_connectable_device_pool(cache, resource_id) do
    rid_bytes = Ecto.UUID.dump!(resource_id)

    case Enum.find(cache.connectable_resources, &(&1.id == rid_bytes)) do
      %Cache.Cacheable.Resource{type: :device_pool} = pool -> {:ok, pool}
      _ -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  # Only a pool that names its members reaches the v2 protocol, and the cache holds those
  # members, so the address is answered without a query.
  defp authorize_pool_target(%Cache.Cacheable.Resource{id: rid_bytes}, cache, target) do
    Cache.Client.authorize_device_access(cache, Ecto.UUID.load!(rid_bytes), target)
  end

  defp resolve_device_domain(domain, socket) do
    with {:ok, label} <- device_domain_label(domain) do
      resolve_device_label(label, socket)
    end
  end

  defp resolve_device_label(label, socket) do
    case fetch_reachable_device(label, socket) do
      {:ok, device} ->
        {:ok, device}

      {:error, :not_found} ->
        if List.keymember?(browsable_device_pools(socket), label, 0),
          do: {:error, :not_a_device},
          else: {:error, :not_found}
    end
  end

  defp browse_device_domain(domain, socket) do
    pools = browsable_device_pools(socket)

    if String.downcase(domain) == Portal.Device.domain() do
      labels = for {label, _pool} <- pools, uniq: true, do: label

      {:ok, labels |> Enum.sort() |> Enum.take(@device_domain_browse_limit), length(labels)}
    else
      with {:ok, label} <- device_domain_label(domain) do
        browse_device_label(label, pools, socket)
      end
    end
  end

  defp browse_device_label(label, pools, socket) do
    criteria = for {^label, pool} <- pools, do: pool.device_membership_criteria

    case criteria do
      [] ->
        with {:ok, _device} <- fetch_reachable_device(label, socket), do: {:ok, [], 0}

      criteria ->
        {slugs, total} =
          Database.member_slugs(criteria, @device_domain_browse_limit, socket.assigns.subject)

        {:ok, slugs, total}
    end
  end

  defp device_domain_label(domain) do
    domain = String.downcase(domain)
    label = domain |> String.split(".") |> hd()

    if domain == Portal.Device.fqdn_for_slug(label),
      do: {:ok, label},
      else: {:error, :not_found}
  end

  defp fetch_reachable_device(slug, socket) do
    with {:ok, %Portal.Device{} = device} <- Database.get_device_by_slug(slug, socket.assigns.subject),
         true <- reachable_through_any_pool?(device, socket) || {:error, :not_found} do
      {:ok, device}
    end
  end

  # The pools the client could get access through, each with the DNS label its name gives:
  # the checks of `pick_device_pool/3` without a target the pool has to hold.
  defp browsable_device_pools(socket) do
    %{cache: cache, client: client, subject: subject} = socket.assigns

    pools =
      for %Cache.Cacheable.Resource{type: :device_pool, id: id} = pool <-
            cache.connectable_resources,
          resource_id = Ecto.UUID.load!(id),
          match?(
            {:ok, _resource, _membership_id, _policy_id, _expires_at},
            Cache.Client.authorize_resource(cache, client, resource_id, subject)
          ),
          into: %{},
          do: {resource_id, pool}

    for {resource_id, label} <- Database.device_pool_labels(Map.keys(pools), subject),
        do: {label, Map.fetch!(pools, resource_id)}
  end

  # Whether any pool the client holds admits the device, judged the same way a packet for it
  # would be, so a name resolves exactly when the client could use the answer.
  defp reachable_through_any_pool?(device, socket) do
    pool_ids =
      for %Cache.Cacheable.Resource{type: :device_pool, id: id} <-
            socket.assigns.cache.connectable_resources,
          do: Ecto.UUID.load!(id)

    match?(
      {:ok, _resource, _membership_id, _policy_id, _expires_at},
      pick_device_pool(pool_ids, device, socket)
    )
  end

  defp schedule_after_constant_time(started_at, message) do
    constant_time =
      Portal.Config.get_env(:portal, __MODULE__, [])
      |> Keyword.get(:device_lookup_constant_time, @device_lookup_constant_time)

    Process.send_after(
      self(),
      message,
      Portal.Timing.remaining_constant_time(started_at, constant_time)
    )
  end

  defp find_online_client_by_address(account_id, {:ipv4, ipv4_tuple}) do
    case Presence.Devices.Account.find_by_ipv4(account_id, ipv4_tuple) do
      {target_client_id, target_meta} -> {:ok, target_client_id, target_meta}
      nil -> :offline
    end
  end

  defp find_online_client_by_address(account_id, {:ipv6, ipv6_tuple}) do
    case Presence.Devices.Account.find_by_ipv6(account_id, ipv6_tuple) do
      {target_client_id, target_meta} -> {:ok, target_client_id, target_meta}
      nil -> :offline
    end
  end

  defp handle_request_gateway_authorization(
         resource_id,
         resource,
         membership_id,
         policy_id,
         expires_at,
         connected_gateway_ids,
         socket,
         address
       ) do
    case Routing.select_receiver(resource, initiator(socket), connected_gateway_ids) do
      {:ok, gateway} ->
        gateway_public_key = gateway.public_key

        policy_authorization_id = Ecto.UUID.generate()
        request_ref = make_ref()

        secrets =
          connection_secrets(
            socket,
            :gateway,
            gateway,
            gateway_public_key,
            resource,
            policy_authorization_id,
            policy_id,
            expires_at
          )

        message =
          {:authorize, {self(), request_ref},
           authorize_request(socket, resource, policy_authorization_id, expires_at, secrets)}

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

        case Portal.Queue.enqueue(Portal.Queue.name(:policy_authorization_queue), attrs,
               dispatch: fn ->
                 PG.deliver(
                   gateway.id,
                   attach_policy_authorization(message, policy_authorization)
                 )
               end
             ) do
          :ok ->
            {:noreply,
             arm_gateway_authorization_timer(
               socket,
               resource_id,
               request_ref,
               gateway.id,
               secrets.initiator_token,
               address
             )}

          {:error, _reason} ->
            push_authorization_creation_failed(socket, resource_id, :offline, address)
            {:noreply, socket}
        end

      {:error, :offline} ->
        push_authorization_creation_failed(socket, resource_id, :offline, address)
        {:noreply, socket}

      {:error, :version_mismatch} ->
        push_authorization_creation_failed(socket, resource_id, :version_mismatch, address)
        {:noreply, socket}
    end
  end

  defp push_authorization_creation_failed(socket, resource_id, reason, address) do
    Protocol.push(
      socket,
      authorization_creation_failed_event(socket),
      Map.merge(%{resource_id: resource_id, reason: reason}, address_fields(address))
    )
  end

  defp handle_request_access(%{"resource_ids" => resource_ids} = payload, socket)
       when is_list(resource_ids) and resource_ids != [] do
    with {:ok, resource_ids} <- parse_resource_ids(resource_ids) do
      case parse_target_address(payload) do
        {:ok, target} ->
          handle_request_device_access(resource_ids, target, payload, socket)

        {:error, :missing_address} ->
          handle_request_resource_access(hd(resource_ids), payload, socket)

        {:error, reason} ->
          push_device_access_denied(socket, payload, reason)
      end
    else
      :error -> push_device_access_denied(socket, payload, :invalid_resource_ids)
    end
  end

  defp handle_request_access(payload, socket) do
    push_device_access_denied(socket, payload, :missing_resource_ids)
  end

  defp parse_resource_ids(resource_ids) do
    Enum.reduce_while(resource_ids, {:ok, []}, fn resource_id, {:ok, acc} ->
      case Ecto.UUID.cast(resource_id) do
        {:ok, resource_id} -> {:cont, {:ok, [resource_id | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, resource_ids} -> {:ok, Enum.reverse(resource_ids)}
      :error -> :error
    end
  end

  defp handle_request_resource_access(resource_id, payload, socket) do
    case Cache.Client.authorize_resource(
           socket.assigns.cache,
           socket.assigns.client,
           resource_id,
           socket.assigns.subject
         ) do
      {:ok, %Cache.Cacheable.Resource{type: :device_pool}, _membership_id, _policy_id, _expires_at} ->
        Protocol.push(socket, authorization_creation_failed_event(socket), %{
          resource_id: resource_id,
          reason: :missing_address
        })

        {:noreply, socket}

      result ->
        handle_authorized_gateway_resource(
          result,
          resource_id,
          Map.get(payload, "connected_gateway_ids", []),
          socket
        )
    end
  end

  defp handle_authorized_gateway_resource(result, resource_id, connected_gateway_ids, socket) do
    case result do
      {:ok, resource, membership_id, policy_id, expires_at} ->
        handle_request_gateway_authorization(
          resource_id,
          resource,
          membership_id,
          policy_id,
          expires_at,
          connected_gateway_ids,
          socket,
          nil
        )

      {:error, :not_found} ->
        Protocol.push(socket, authorization_creation_failed_event(socket), %{
          resource_id: resource_id,
          reason: :not_found
        })

        {:noreply, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        Protocol.push(socket, authorization_creation_failed_event(socket), %{
          resource_id: resource_id,
          reason: :forbidden,
          violated_properties: violated_properties
        })

        {:noreply, socket}
    end
  end

  # The target's presence carries everything the criteria compare against, so an online
  # device is authorized without a query. An offline device is read once to tell "offline"
  # from "not in any of these pools".
  defp handle_request_device_access(resource_ids, target, payload, socket) do
    started_at = System.monotonic_time(:millisecond)
    account_id = socket.assigns.client.account_id

    case find_online_client_by_address(account_id, target) do
      {:ok, target_client_id, target_meta} when target_client_id != socket.assigns.client.id ->
        member = %{
          id: target_client_id,
          account_id: account_id,
          actor_id: target_meta.actor_id,
          group_ids: Map.get(target_meta, :group_ids, [])
        }

        case pick_device_pool(resource_ids, member, socket) do
          {:ok, resource, membership_id, policy_id, expires_at} ->
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

          {:error, :forbidden} ->
            deny_device_access(socket, payload, started_at)
        end

      {:ok, _self_id, _meta} ->
        deny_device_access(socket, payload, started_at)

      :offline ->
        with {:ok, %Portal.Device{} = device} <- fetch_target_device(target, socket),
             {:ok, _resource, _membership_id, _policy_id, _expires_at} <-
               pick_device_pool(resource_ids, device, socket) do
          push_device_access_denied(socket, Map.put(payload, "client_id", device.id), :offline)
        else
          _other -> deny_device_access(socket, payload, started_at)
        end
    end
  end

  # An address no device holds answers exactly like one the asking client may not reach, and
  # after the same delay, so sweeping the tunnel range tells an actor nothing about who is in
  # it. A device the client may reach answers straight away, offline or not.
  defp deny_device_access(socket, payload, started_at) do
    schedule_after_constant_time(started_at, {:device_access_denied, payload, :forbidden})

    {:noreply, socket}
  end

  # Walks the pools connlib named, in its order, and grants the first the client may use
  # that holds the target.
  defp pick_device_pool(resource_ids, target, socket) do
    Enum.find_value(resource_ids, {:error, :forbidden}, fn resource_id ->
      with {:ok, pool} <- fetch_connectable_device_pool(socket.assigns.cache, resource_id),
           true <-
             Portal.Resource.DeviceMembershipCriteria.member?(
               pool.device_membership_criteria,
               target,
               socket.assigns.subject
             ),
           {:ok, _resource, _membership_id, _policy_id, _expires_at} = authorized <-
             Cache.Client.authorize_resource(
               socket.assigns.cache,
               socket.assigns.client,
               resource_id,
               socket.assigns.subject
             ) do
        authorized
      else
        _ -> nil
      end
    end)
  end

  defp push_device_access_denied(socket, payload, reason) do
    Protocol.push(
      socket,
      "client_device_access_denied",
      %{ipv4: payload["ipv4"], ipv6: payload["ipv6"], reason: reason}
      |> maybe_put_client_id(payload["client_id"])
    )

    {:noreply, socket}
  end

  defp maybe_put_client_id(payload, nil), do: payload
  defp maybe_put_client_id(payload, client_id), do: Map.put(payload, :client_id, client_id)

  defp handle_request_pool_authorization(
         resource_id,
         resource,
         membership_id,
         policy_id,
         expires_at,
         payload,
         socket
       ) do
    account_id = socket.assigns.client.account_id

    with {:ok, target} <- parse_target_address(payload),
         {:ok, target_device_id} <- authorize_pool_target(resource, socket.assigns.cache, target) do
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
          Protocol.push(socket, "client_device_access_denied", %{
            client_id: target_device_id,
            ipv4: payload["ipv4"],
            ipv6: payload["ipv6"],
            reason: :offline
          })

          {:noreply, socket}
      end
    else
      {:error, :ambiguous_address} ->
        Logger.warning("request_authorization for pool included both ipv4 and ipv6",
          client_id: socket.assigns.client.id,
          resource_id: resource_id
        )

        Protocol.push(socket, "client_device_access_denied", %{
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :ambiguous_address
        })

        {:noreply, socket}

      {:error, :missing_address} ->
        Protocol.push(socket, "client_device_access_denied", %{
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

        Protocol.push(socket, "client_device_access_denied", %{
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :invalid_address
        })

        {:noreply, socket}

      {:error, :forbidden} ->
        Protocol.push(socket, "client_device_access_denied", %{
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
        Protocol.push(socket, "client_device_access_denied", %{
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
      last_seen_remote_ip: target_meta.remote_ip
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
    # authorization onto the target's websocket (`{:authorized, ref, _}`).
    # Until then the initiator must not start ICE, because its candidates
    # travel the same socket as the authorization and would otherwise race
    # ahead of it at the target's data plane.
    ref = make_ref()

    {receiver_message, initiator_payload} =
      build_device_access_messages(
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

    case Portal.Queue.enqueue(Portal.Queue.name(:policy_authorization_queue), attrs,
           dispatch: fn ->
             PG.deliver(
               target_client_id,
               attach_policy_authorization(receiver_message, policy_authorization)
             )
           end
         ) do
      :ok ->
        timer_ref =
          Process.send_after(
            self(),
            {:authorization_creation_timeout, ref},
            authorization_creation_timeout()
          )

        pending =
          Map.put(socket.assigns.pending_authorizations, ref, %{
            timer_ref: timer_ref,
            initiator_payload: initiator_payload,
            policy_authorization_id: policy_authorization_id,
            target_client_id: target_client_id,
            resource_id: resource_id,
            expires_at: expires_at,
            deny_payload: %{
              client_id: target_client_id,
              ipv4: payload["ipv4"],
              ipv6: payload["ipv6"],
              reason: :offline
            }
          })

        {:noreply, assign(socket, :pending_authorizations, pending)}

      {:error, _} ->
        Protocol.push(socket, "client_device_access_denied", %{
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
  # carries `{self(), ref}` so the target's channel can reply `:authorized` once
  # it has pushed the authorization onto the target's websocket; the
  # initiator_payload is released to the originating client only after that.
  defp build_device_access_messages(
         target_client_id,
         target_meta,
         resource,
         policy_authorization_id,
         policy_id,
         expires_at,
         ref,
         socket
       ) do
    target_client = %Portal.Device{
      id: target_client_id,
      psk_base: target_meta.psk_base,
      type: :client
    }

    secrets =
      connection_secrets(
        socket,
        :client,
        target_client,
        target_meta.public_key,
        resource,
        policy_authorization_id,
        policy_id,
        expires_at
      )

    receiver_message =
      {:authorize, {self(), ref},
       authorize_request(socket, resource, policy_authorization_id, expires_at, secrets)}

    initiator_payload = %{
      client_id: target_client_id,
      resource_id: Ecto.UUID.load!(resource.id),
      client_public_key: target_meta.public_key,
      client_ipv4: %Postgrex.INET{address: target_meta.ipv4},
      client_ipv6: %Postgrex.INET{address: target_meta.ipv6},
      preshared_key: secrets.preshared_key,
      local_ice_credentials: secrets.ice_credentials.initiator,
      remote_ice_credentials: secrets.ice_credentials.receiver,
      ice_role: :controlling,
      flow_logs_ingest_token: secrets.initiator_token
    }

    {receiver_message, initiator_payload}
  end

  # Each receiver renders the initiator and resource for its own protocol.
  defp authorize_request(socket, resource, policy_authorization_id, expires_at, secrets) do
    client = socket.assigns.client

    %{
      initiator:
        client
        |> Map.take([
          :id,
          :name,
          :slug,
          :public_key,
          :ipv4,
          :ipv6,
          :device_serial,
          :device_uuid,
          :firebase_installation_id,
          :identifier_for_vendor
        ])
        |> Map.put(:user_agent, socket.assigns.subject.context.user_agent),
      # Kept for older gateways that do not report flow logs to the portal.
      # These do not parse the attribution fields from the ingest token.
      subject: PortalAPI.Gateway.Views.Subject.render(socket.assigns.subject),
      resource: resource,
      policy_authorization_id: policy_authorization_id,
      expires_at: expires_at,
      preshared_key: secrets.preshared_key,
      ice_credentials: secrets.ice_credentials,
      responder_token: secrets.responder_token,
      initiator_iceless_capable: socket.assigns.iceless_capable
    }
  end

  defp relay_owner(socket) do
    %{
      device: socket.assigns.client,
      location:
        {socket.assigns.subject.context.remote_ip_location_lat,
         socket.assigns.subject.context.remote_ip_location_lon},
      expires_at: socket.assigns.subject.expires_at
    }
  end

  defp initiator(socket) do
    %{
      account_id: socket.assigns.subject.account.id,
      device_id: socket.assigns.client.id,
      version: socket.assigns.client_version,
      proto_range: proto_range(socket),
      location:
        {socket.assigns.subject.context.remote_ip_location_lat,
         socket.assigns.subject.context.remote_ip_location_lon}
    }
  end

  # A device that states its range has it assigned; a legacy client speaks its own minor.
  defp proto_range(socket) do
    Map.get(socket.assigns, :proto_range) ||
      Portal.Version.legacy_proto_range(:client, socket.assigns.client_version)
  end

  # The socket read these before the channel subscribed, so a change in between would be lost.
  defp refresh_connect_state(socket, device) do
    current = socket.assigns.client
    account = SchemaHelpers.merge_broadcast(socket.assigns.subject.account, device.account)
    subject = %{socket.assigns.subject | account: account}
    client = Device.merge_broadcast(current, %{device | actor: current.actor, account: current.account})
    socket = assign(socket, subject: subject, client: client)

    assign(socket, :client, %{client | posture: load_posture_rows(socket)})
  end

  defp hydrate_and_init(socket) do
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
        socket.assigns.subject,
        protocol_version: protocol_version(socket)
      )

    # Hydrate the policy_authorizations caches so the channel can react to filter
    # changes and policy_authorization deletions for resources another client has been
    # authorized to access via this one.
    {authorizations_cache, outbound_authorizations_cache} =
      Cache.Client.Authorizations.hydrate(socket.assigns.client)

    # Subscribe before selecting relays so no relay presence change is missed.
    :ok = Presence.Relays.subscribe()
    relays = Relays.select(relay_owner(socket))

    socket =
      socket
      # Cache relay IDs and stamp secrets for tracking
      |> Relays.cache(relays)
      |> assign(
        cache: cache,
        authorizations_cache: authorizations_cache,
        outbound_authorizations_cache: outbound_authorizations_cache,
        pending_authorizations: %{},
        iceless_capable: Map.get(socket.assigns, :iceless_capable, false)
      )
      # Track client's presence and monitor tracker shard processes for crash recovery
      |> track_presence()

    with {:noreply, socket} <- register(socket) do
      init(socket, resources, relays)

      :ok =
        PortalAPI.Sockets.notify_public_key_changed(
          socket.assigns.client,
          socket.assigns[:previous_public_key]
        )

      {:noreply, socket}
    end
  end

  defp init(socket, resources, relays) do
    payload = %{
      flow_logs: flow_logs_config(),
      account_slug: socket.assigns.subject.account.slug,
      actor_name: socket.assigns.subject.actor.name,
      resources: Views.Resource.render_many(resources, socket.assigns.client, protocol_version(socket)),
      authorizations: Views.PolicyAuthorization.render_many(socket.assigns.authorizations_cache),
      relays:
Relays.render(relays, relay_owner(socket)),
      interface:
        Views.Interface.render(%{
          socket.assigns.client
          | account: socket.assigns.subject.account
        })
    }

    Protocol.push(socket, "init", protocol_extension(socket, :extend_init, payload))
  end

  defp reinitialize_client(socket) do
    relays = Relays.select(relay_owner(socket))
    socket = Relays.cache(socket, relays)

    init(socket, socket.assigns.cache.connectable_resources, relays)
    track_presence(socket)
  end

  @doc false
  def flow_logs_config do
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

  # Gateways and receiving clients get the same secrets for a connection.
  defp connection_secrets(
         socket,
         receiver_type,
         receiver,
         receiver_public_key,
         resource,
         policy_authorization_id,
         policy_id,
         expires_at
       ) do
    initiator = socket.assigns.client

    {initiator_token, responder_token} =
      mint_ingest_tokens(
        socket.assigns.subject,
        {Ecto.UUID.load!(resource.id), resource.name, resource.type, resource.address},
        policy_authorization_id,
        policy_id,
        flow_log_uploads_enabled?(socket.assigns.cache, policy_id),
        initiator,
        {receiver_type, receiver.id},
        expires_at
      )

    %{
      preshared_key: Portal.Crypto.psk(initiator, initiator.public_key, receiver, receiver_public_key),
      ice_credentials:
        generate_ice_credentials(initiator.public_key, initiator, receiver, receiver_public_key),
      initiator_token: initiator_token,
      responder_token: responder_token
    }
  end

  # ICE credentials must stay the same for all connections between an initiator and a receiver as long
  # as they do not lose their state, so we can leverage their public keys, which are reset on each
  # restart of an initiator or a receiver. The secret psk_base keys the HMAC so nobody can compute them.
  defp generate_ice_credentials(
         initiator_pubkey,
         %Device{psk_base: initiator_psk_base} = initiator,
         %Device{psk_base: receiver_psk_base} = receiver,
         receiver_pubkey
       )
       when is_binary(initiator_psk_base) and is_binary(receiver_psk_base) do
    ice_credential_seed =
      ["ICE_CREDS", initiator.id, initiator_pubkey, receiver.id, receiver_pubkey]
      |> Enum.join(":")

    ice_credential_seed_hash =
      :crypto.mac(:hmac, :sha256, initiator_psk_base <> receiver_psk_base, ice_credential_seed)
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

  # ACTORS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Actor{id: actor_id, is_disabled: false},
           struct: %Portal.Actor{id: actor_id, is_disabled: true}
         },
         %{assigns: %{subject: %{actor: %{id: actor_id}}}} = socket
       ) do
    handle_info(:disconnect, socket)
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.Actor{id: actor_id}},
         %{assigns: %{subject: %{actor: %{id: actor_id}}}} = socket
       ) do
    handle_info(:disconnect, socket)
  end

  # TRUST ANCHORS

  # Editing or deleting a trust anchor deletes its certificate rows. A session
  # that came in on a certificate reconnects, so Socket.connect/3 checks it
  # against the anchors that remain.
  defp handle_change(
         %Change{op: :delete, old_struct: %Portal.TrustAnchorCertificate{}},
         socket
       ) do
    if certificate_session?(socket) do
      Session.close_transport(socket)
    else
      {:noreply, socket}
    end
  end

  # X.509 AUTH PROVIDERS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.X509.AuthProvider{
             id: auth_provider_id,
             is_disabled: false
           },
           struct: %Portal.X509.AuthProvider{
             id: auth_provider_id,
             is_disabled: true
           }
         },
         %{
           assigns: %{
             subject: %{
               credential: %Credential.X509{auth_provider_id: auth_provider_id}
             }
           }
         } = socket
       ) do
    handle_info(:disconnect, socket)
  end

  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Portal.X509.AuthProvider{id: auth_provider_id}
         },
         %{
           assigns: %{
             subject: %{
               credential: %Credential.X509{auth_provider_id: auth_provider_id}
             }
           }
         } = socket
       ) do
    handle_info(:disconnect, socket)
  end

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
    account = SchemaHelpers.merge_broadcast(socket.assigns.subject.account, account)
    subject = %{socket.assigns.subject | account: account}
    socket = assign(socket, subject: subject)

    if old_account.config != account.config do
      client = %{socket.assigns.client | account: account}
      payload = %{interface: Views.Interface.render(client)}
      :ok = Protocol.push(socket, "config_changed", payload)
    end

    if Portal.Account.device_posture_enabled?(old_account) != Portal.Account.device_posture_enabled?(account) do
      refresh_posture_rows(socket)
    else
      {:noreply, socket}
    end
  end

  # MEMBERSHIPS

  defp handle_change(
         %Change{op: :insert, struct: %Portal.Membership{actor_id: actor_id}},
         %{assigns: %{client: %{actor_id: id}}} = socket
       )
       when id == actor_id do
    {:noreply, socket} =
      Cache.Client.add_membership(
        socket.assigns.cache,
        socket.assigns.client,
        socket.assigns.subject
      )
      |> push_resource_updates(socket)

    {:noreply, track_presence(socket)}
  end

  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Portal.Membership{actor_id: actor_id} = membership
         },
         %{assigns: %{client: %{actor_id: id}}} = socket
       )
       when id == actor_id do
    {:noreply, socket} =
      Cache.Client.delete_membership(
        socket.assigns.cache,
        membership,
        socket.assigns.client,
        socket.assigns.subject
      )
      |> push_resource_updates(socket)

    {:noreply, track_presence(socket)}
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
    updated_client = Device.merge_broadcast(current_client, client)

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
        socket.assigns.subject
      )
      |> push_resource_updates(socket)
    else
      {:noreply, socket}
    end
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
             conditions: old_conditions,
             postures: old_postures,
             device_trust: old_device_trust
           },
           struct: %Portal.Policy{
             resource_id: resource_id,
             group_id: group_id,
             conditions: conditions,
             postures: postures,
             device_trust: device_trust,
             is_disabled: is_disabled
           }
         } = change,
         socket
       )
       when old_resource_id != resource_id or old_group_id != group_id or
              old_conditions != conditions or old_postures != postures or
              old_device_trust != device_trust do
    # TODO: Optimization
    # Breaking update - process this as a delete and then create to make our lives easier.
    # We could be smarter here and process the individual side effects more cleverly to avoid
    # sending resource_deleted and resource_created_or_updated if the policy is not actually changing
    # the client's connectable_resources.
    {:noreply, socket} = handle_change(%{change | op: :delete}, socket)

    # DO NOT re-add disabled policies
    if is_disabled do
      {:noreply, socket}
    else
      handle_change(%{change | op: :insert}, socket)
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
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  # POLICY_AUTHORIZATIONS

  # On the v3 protocol the initiating side keeps the pool as its route to the peer, so
  # it gets the same reject_access when the authorization goes away and asks the portal
  # again on the next flow. Authorizations cascade on device and policy deletes, so a
  # deleted target or a revoked policy both end up here.
  defp handle_change(
         %Change{
           op: :delete,
           old_struct:
             %Portal.PolicyAuthorization{initiating_device_id: client_id} = policy_authorization
         },
         %{assigns: %{client: %{id: client_id}}} = socket
       ) do
    socket = delete_outbound_authorization(socket, policy_authorization)

    if protocol_version(socket) >= 3 and
         not expired?(policy_authorization) do
      Protocol.push(
        socket,
        "reject_access",
        %{
          client_id: policy_authorization.receiving_device_id,
          resource_id: policy_authorization.resource_id
        },
        :outbound
      )
    end

    {:noreply, socket}
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

    {:ok, _added, _removed_ids, cache} =
      result =
      Cache.Client.update_resource(
        socket.assigns.cache,
        resource,
        socket.assigns.client,
        socket.assigns.subject
      )

    for addresses <- Cache.Client.removed_member_addresses(socket.assigns.cache, cache) do
      push_device_access_denied(socket, addresses)
    end

    push_resource_updates(result, socket)
  end

  # NON-SELF DEVICES (members of a pool we have access to)

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Device{},
           struct: %Portal.Device{} = device
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
         %Change{op: :delete, old_struct: %Portal.Device{} = device},
         socket
       ) do
    {:ok, denied, added, removed_ids, cache} =
      Cache.Client.handle_member_device_delete(socket.assigns.cache, device)

    push_device_access_denied(socket, denied)
    push_resource_updates({:ok, added, removed_ids, cache}, socket)
  end

  # POSTURE ROWS
  #
  # Every provider row change in the account arrives here, so only one that
  # carries an identifier of this device is acted on. The rows are then read
  # back from the database rather than patched in memory, which also picks up
  # a Defender row newly linked through an Intune row.
  defp handle_change(%Change{} = change, socket) do
    if posture_provider_toggled?(change) or
         (posture_row_change?(change) and concerns_client?(change, socket.assigns.client)) do
      refresh_posture_rows(socket)
    else
      {:noreply, socket}
    end
  end

  # A disabled provider's rows count as absent, and the rows themselves do not change.
  defp posture_provider_toggled?(%Change{op: :update, old_struct: %module{} = old, struct: %module{} = new}) do
    module in @posture_provider_schemas and old.is_disabled != new.is_disabled
  end

  defp posture_provider_toggled?(%Change{}), do: false

  defp posture_row_change?(%Change{struct: %module{}}), do: module in Devices.Posture.schemas()
  defp posture_row_change?(%Change{old_struct: %module{}}), do: module in Devices.Posture.schemas()
  defp posture_row_change?(%Change{}), do: false

  defp concerns_client?(%Change{old_struct: old_row, struct: row}, client) do
    row_keys = Enum.flat_map([old_row, row], &if(is_nil(&1), do: [], else: Devices.Posture.row_keys(&1)))
    client_keys = Devices.Posture.device_keys(client) ++ Devices.Posture.entra_keys(client.posture)

    Enum.any?(row_keys, &(&1 in client_keys))
  end

  defp refresh_posture_rows(socket) do
    client = socket.assigns.client
    rows = load_posture_rows(socket)

    if rows == client.posture do
      {:noreply, socket}
    else
      client = %{client | posture: rows}

      socket = assign(socket, :client, client)

      Cache.Client.recompute_connectable_resources(socket.assigns.cache, client, socket.assigns.subject)
      |> push_resource_updates(socket)
    end
  end

  defp load_posture_rows(socket) do
    if Portal.Account.device_posture_enabled?(socket.assigns.subject.account) do
      Devices.Posture.rows_by_type(socket.assigns.client)
    else
      %{}
    end
  end

  defp protocol_version(socket), do: socket.assigns.channel_protocol.protocol_version()

  # A protocol that adds to what every client gets defines the callback; the others leave it as is.
  defp protocol_extension(socket, callback, value) do
    protocol = socket.assigns.channel_protocol

    if function_exported?(protocol, callback, 2) do
      apply(protocol, callback, [socket, value])
    else
      value
    end
  end

  defp expired?(%Portal.PolicyAuthorization{expires_at: nil}), do: false

  defp expired?(%Portal.PolicyAuthorization{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp push_device_access_denied(_socket, nil), do: :ok

  defp push_device_access_denied(socket, {ipv4_tuple, ipv6_tuple}) do
    Protocol.push(socket, "client_device_access_denied", %{
      ipv4: to_string(:inet.ntoa(ipv4_tuple)),
      ipv6: to_string(:inet.ntoa(ipv6_tuple)),
      reason: :forbidden
    })

    :ok
  end

  defp maybe_put_expires_at(payload, %DateTime{} = expires_at),
    do: Map.put(payload, :expires_at, DateTime.to_unix(expires_at, :second))

  defp maybe_put_expires_at(payload, _expires_at), do: payload

  defp maybe_push_resource_filters_updated(_socket, _resource, filters, filters), do: :ok

  defp maybe_push_resource_filters_updated(socket, resource, _old_filters, _filters) do
    if Cache.Authorizations.has_resource?(socket.assigns.authorizations_cache, resource.id) do
      cacheable = Cache.Cacheable.to_cache(resource)
      Protocol.push(socket, "resource_filters_updated", Views.Resource.render_authorization(cacheable))
    end

    :ok
  end

  defp push_resource_updates({:ok, added_resources, removed_ids, cache}, socket) do
    # Currently, connlib doesn't handle resources changing sites, so we need to delete then create.
    # We handle that scenario by sending resource_deleted then resource_created_or_updated, so it's
    # important that deletions are processed first here.
    # See https://github.com/firezone/firezone/issues/9881
    for resource_id <- removed_ids do
      Protocol.push(socket, "resource_deleted", resource_id)
    end

    for resource <- added_resources do
      Protocol.push(
        socket,
        "resource_created_or_updated",
        Views.Resource.render(resource, socket.assigns.client, protocol_version(socket))
      )
    end

    {:noreply, assign(socket, cache: cache)}
  end

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
           last_seen_remote_ip: receiver_remote_ip
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

  # Whether flow logs may be uploaded for a flow this policy authorizes, which
  # is to say whether the policy has opted out. Stamped into the ingest token
  # so devices know whether to upload and the ingest endpoint can enforce it. A
  # policy missing from the cache fails closed to false.
  defp flow_log_uploads_enabled?(cache, policy_id) do
    match?(
      %Cache.Cacheable.Policy{flow_log_uploads_enabled: true},
      Map.get(cache.policies, Ecto.UUID.dump!(policy_id))
    )
  end

  # Mints the pair of per-flow ingest tokens for an authorization: one for the
  # initiator (the client) and one for the responder (the gateway or receiving
  # client). Each token snapshots the attribution the corresponding device must
  # report and is the sole authenticator for its flow-log uploads. Both tokens
  # name both endpoint devices. Only `role` differs between them, except that a
  # receiving client's token leaves out `@admin_only_initiator_claims`.
  defp mint_ingest_tokens(
         %Authentication.Subject{account: account, actor: actor, credential: credential} = subject,
         {resource_id, resource_name, resource_type, resource_address},
         policy_authorization_id,
         policy_id,
         flow_log_uploads_enabled,
         %Device{type: :client} = initiator_client,
         {responder_type, responder_device_id},
         expires_at
       ) do
    {os_name, os_version, client_version} =
      PortalAPI.Gateway.Views.Client.parse_user_agent(subject.context.user_agent)

    attribution = %{
      # The authorization this batch of flow logs reports against. The ingest
      # endpoint rejects a request whose records mix more than one of these.
      "policy_authorization_id" => policy_authorization_id,
      "policy_id" => policy_id,
      # The same pair as the authorization's initiating_device_id /
      # receiving_device_id. Shared by both tokens so either side's row names
      # the pair without a join; `role` says which of the two wrote it.
      "initiator_device_id" => initiator_client.id,
      "responder_device_id" => responder_device_id,
      # Whether the authorizing policy allows this flow's logs to be uploaded
      # (policies.flow_log_uploads_enabled).
      # Devices honor it and the ingest endpoint enforces it, so the token can
      # always be minted while uploads stay policy-gated. The claim name is the
      # data-plane contract: connlib parses it as a required field.
      "uploads_enabled" => flow_log_uploads_enabled,
      "resource_id" => resource_id,
      "resource_name" => resource_name,
      "resource_address" => resource_address,
      # Ingestion checks each record's inner tunnel tuple against these: the
      # source must be the initiator and an IP or CIDR resource must contain
      # the destination.
      "resource_type" => Atom.to_string(resource_type),
      "initiator_ips" =>
        for(ip <- [initiator_client.ipv4, initiator_client.ipv6], ip, do: Portal.Types.IP.to_string(ip)),
      # For client-to-client flows the receiving client's own owner is
      # deliberately not part of this snapshot.
      "initiator_actor_id" => actor.id,
      "initiator_actor_email" => actor.email,
      "initiator_actor_name" => actor.name,
      "initiator_auth_provider_id" => Credential.auth_provider_id(credential),
      # The authorization happens now; both tokens share the same authorized_at
      # so the two sides of the flow agree on the trusted flow_start floor.
      "authorized_at" => DateTime.to_iso8601(DateTime.utc_now()),
      # When this authorization expires (independent of the token's own exp,
      # which adds a reporting grace window on top). Stamped so the flow_log row
      # records the actual authorization lifetime.
      "authorization_expires_at" => DateTime.to_iso8601(expires_at),
      # The connecting client's device telemetry. It describes the initiating
      # client on both sides of the flow, so it is shared by both tokens and
      # named for the side it describes rather than for the reporter.
      "initiator_client_version" => client_version,
      "initiator_device_os_name" => os_name,
      "initiator_device_os_version" => os_version,
      "initiator_device_serial" => initiator_client.device_serial,
      "initiator_device_uuid" => initiator_client.device_uuid,
      "initiator_device_identifier_for_vendor" => initiator_client.identifier_for_vendor,
      "initiator_device_firebase_installation_id" => initiator_client.firebase_installation_id
    }

    initiator_token =
      FlowLogToken.mint(account, Map.put(attribution, "role", "initiator"), expires_at)

    responder_attribution =
      case responder_type do
        :gateway -> attribution
        :client -> Map.drop(attribution, @admin_only_initiator_claims)
      end

    responder_token =
      FlowLogToken.mint(account, Map.put(responder_attribution, "role", "responder"), expires_at)

    {initiator_token, responder_token}
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
  # `{tag, {channel_pid, ref}, payload}` (used by :allow_access, :authorize and
  # :request_connection).
  defp attach_policy_authorization({tag, ref_tuple, payload}, %Portal.PolicyAuthorization{} = pa)
       when is_tuple(ref_tuple) do
    {tag, ref_tuple, Map.put(payload, :policy_authorization, pa)}
  end

  defp arm_gateway_authorization_timer(
         socket,
         resource_id,
         generation,
         gateway_id,
         initiator_token,
         address
       ) do
    # Cancel any timer a prior in-flight request_authorization armed under this key.
    case Map.get(socket.assigns.pending_authorizations, resource_id) do
      {_old_generation, old_timer_ref, _old_initiator_token, _old_address, _old_gateway_id} ->
        Process.cancel_timer(old_timer_ref)

      nil ->
        :ok
    end

    timer_ref =
      Process.send_after(
        self(),
        {:authorization_creation_timeout, resource_id, generation},
        authorization_creation_timeout()
      )

    assign(
      socket,
      :pending_authorizations,
      Map.put(
        socket.assigns.pending_authorizations,
        resource_id,
        {generation, timer_ref, initiator_token, address, gateway_id}
      )
    )
  end

  defp authorization_creation_timeout do
    Portal.Config.get_env(:portal, :authorization_creation_timeout_ms, :timer.seconds(15))
  end

  defp schedule_session_expiry(expires_at) do
    ms = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    Process.send_after(self(), :disconnect, max(ms, 0))
  end

  defp register(socket) do
    case Session.monitor_pg_scope(socket) do
      {:joined, socket, previous_pid} ->
        :ok = PG.register(socket.assigns.client.id)
        :ok = PG.join(socket.assigns.subject.credential.id)

        # The account CDC subscription is already active. Checking current state
        # after subscribing closes the connect race: an earlier change is seen
        # here, while a later one arrives through the CDC-derived broadcast.
        cond do
          not x509_session_enabled?(socket) -> handle_info(:disconnect, socket)
          not trust_anchor_kept?(socket) -> Session.close_transport(socket)
          true -> register_session(socket, previous_pid)
        end

      result ->
        result
    end
  end

  defp x509_session_enabled?(%{
         assigns: %{
           subject: %{
             actor: %{id: actor_id},
             credential: %Credential.X509{auth_provider_id: auth_provider_id}
           }
         }
       }) do
    Database.x509_session_enabled?(auth_provider_id, actor_id)
  end

  defp x509_session_enabled?(_socket), do: true

  defp expire_attestation(%{assigns: %{client: %{attested?: true, attested_until: %DateTime{} = attested_until}}} = socket) do
    if DateTime.compare(DateTime.utc_now(), attested_until) == :gt do
      socket
      |> assign(:client, %{socket.assigns.client | attested?: false, attested_until: nil})
      |> track_presence()
    else
      socket
    end
  end

  defp expire_attestation(socket), do: socket

  defp certificate_session?(%{assigns: %{subject: %{credential: %Credential.X509{}}}}), do: true
  defp certificate_session?(socket), do: not is_nil(socket.assigns[:attestation])

  defp trust_anchor_kept?(%{assigns: %{trust_anchor_certificate_ids: [_ | _] = ids}} = socket),
    do: Database.trust_anchor_certificate_exists?(socket.assigns.client.account_id, ids)

  defp trust_anchor_kept?(_socket), do: true

  # Only enqueue + arm on the first successful registration; re-registrations
  # after a PG scope crash share the same channel and session row.
  defp register_session(socket, nil) do
    Portal.Queue.enqueue(
      Portal.Queue.name(:client_session_queue),
      session_attrs(
        socket.assigns.client,
        socket.assigns.session_ref,
        socket.assigns.client.attested?
      ),
      metadata: %{
        subject: Authentication.Subject.to_map(socket.assigns.subject),
        timestamp: DateTime.utc_now()
      }
    )

    {:noreply, Durability.arm_session(socket)}
  end

  # A token deletion or certificate revocation sent while the scope was down
  # missed its PG delivery.
  defp register_session(socket, _current_pid) do
    cond do
      not client_token_kept?(socket) ->
        handle_info(:disconnect, socket)

      certificate_revoked?(socket) ->
        %{issuer: issuer, serial: serial} = socket.assigns.attestation
        handle_info({:certificate_revoked, issuer, serial}, socket)

      true ->
        {:noreply, socket}
    end
  end

  defp client_token_kept?(%{assigns: %{subject: %{credential: %Credential.ClientToken{id: id}}}} = socket),
    do: Database.client_token_exists?(socket.assigns.client.account_id, id)

  defp client_token_kept?(_socket), do: true

  defp certificate_revoked?(%{assigns: %{attestation: %{issuer: issuer, serial: serial}}} = socket),
    do: Database.certificate_revoked?(socket.assigns.client.account_id, issuer, serial)

  defp certificate_revoked?(_socket), do: false

  defp track_presence(socket) do
    range = proto_range(socket)

    meta =
      protocol_extension(socket, :extend_presence_meta, %{
        group_ids: group_ids(socket.assigns.cache),
        site_ids: Map.get(socket.assigns, :served_site_ids, []),
        capabilities: Map.get(socket.assigns, :capabilities, [:tun]),
        proto_min: range && range.min,
        proto_max: range && range.max
      })

    Session.track_presence(socket, socket.assigns.client, socket.assigns.subject.credential.id, meta)
  end

  # Pool authorization reads the target's groups off its presence, so they must follow
  # its memberships.
  defp group_ids(%{memberships: memberships}) do
    for {gid_bytes, _mid_bytes} <- memberships, do: Ecto.UUID.load!(gid_bytes)
  end

  defp session_attrs(%Portal.Device{} = client, session_ref, attested?) do
    # The attested snapshot is carried only when THIS session proved
    # possession. Copying it off the row for every session would re-assert a
    # stale snapshot and race a fresher proof flushing from another session;
    # the flush's recency guard keeps the row's values when the entry carries
    # none.
    attested_attrs =
      if attested? do
        %{
          last_attested_device_serial: client.last_attested_device_serial,
          last_attested_device_uuid: client.last_attested_device_uuid,
          last_attested_mdm_device_id: client.last_attested_mdm_device_id,
          last_attested_cert_serial: client.last_attested_cert_serial,
          last_attested_cert_fingerprint: client.last_attested_cert_fingerprint,
          last_attested_cert_issuer: client.last_attested_cert_issuer,
          last_attested_at: client.last_attested_at
        }
      else
        %{}
      end

    %{
      session_ref: session_ref,
      account_id: client.account_id,
      device_id: client.id,
      actor_id: client.actor_id,
      # Only carried when this connect actually adopted a new firezone_id:
      # the flush's coalesce keeps the row's current value on nil, and the
      # conflict probe then runs only for real merges instead of every flush.
      firezone_id: if(client.firezone_id_merged?, do: client.firezone_id),
      device_serial: client.device_serial,
      device_uuid: client.device_uuid,
      identifier_for_vendor: client.identifier_for_vendor,
      firebase_installation_id: client.firebase_installation_id,
      token_id: client.token_id,
      public_key: client.public_key,
      user_agent: client.last_seen_user_agent,
      remote_ip: client.last_seen_remote_ip,
      remote_ip_location_region: client.last_seen_remote_ip_location_region,
      remote_ip_location_city: client.last_seen_remote_ip_location_city,
      remote_ip_location_lat: client.last_seen_remote_ip_location_lat,
      remote_ip_location_lon: client.last_seen_remote_ip_location_lon,
      version: client.last_seen_version
    }
    |> Map.merge(attested_attrs)
  end

  defp release_gateway_authorization(socket, resource_id, request_ref, gateway) do
    gateway_id = gateway.receiver_id

    case Map.get(socket.assigns.pending_authorizations, resource_id) do
      {^request_ref, timer_ref, initiator_token, address, ^gateway_id} ->
        Process.cancel_timer(timer_ref)

        reply_payload =
          %{
            resource_id: resource_id,
            preshared_key: gateway.preshared_key,
            client_ice_credentials: gateway.ice_credentials.initiator,
            gateway_id: gateway_id,
            gateway_public_key: gateway.public_key,
            gateway_ipv4: gateway.ipv4,
            gateway_ipv6: gateway.ipv6,
            gateway_ice_credentials: gateway.ice_credentials.receiver,
            use_iceless: gateway.use_iceless,
            flow_logs_ingest_token: initiator_token
          }
          |> put_site_id(gateway.site_id, socket.assigns.client)
          |> Map.merge(address_fields(address))

        Protocol.push(socket, authorization_created_event(socket), reply_payload, gateway)

        {:noreply,
         assign(
           socket,
           :pending_authorizations,
           Map.delete(socket.assigns.pending_authorizations, resource_id)
         )}

      _other ->
        {:noreply, socket}
    end
  end

  defp release_device_access(socket, ref, use_iceless, client_name, client_slug) do
    case Map.pop(socket.assigns.pending_authorizations, ref) do
      {nil, _} ->
        {:noreply, socket}

      {%{timer_ref: timer_ref, initiator_payload: initiator_payload} = pending, remaining} ->
        Process.cancel_timer(timer_ref)

        initiator_payload =
          initiator_payload
          |> Map.put(:use_iceless, use_iceless)
          |> Map.put(:client_name, client_name)
          |> Map.put(:client_slug, client_slug)

        Protocol.push(socket, "client_device_access_authorized", initiator_payload)

        {:noreply,
         socket
         |> assign(:pending_authorizations, remaining)
         |> put_outbound_authorization(pending)}
    end
  end

  # The receiving gateway checks its authorization cache before it forwards the candidates.
  defp deliver_to_gateways(socket, gateway_ids, tag, candidates) when is_list(gateway_ids) do
    candidates = PortalAPI.Sockets.limit_ice_candidates(candidates, socket.assigns.client)

    if candidates != [] do
      gateway_ids = gateway_ids |> Enum.take(@max_ice_candidate_gateways) |> Enum.uniq()

      for gateway_id <- gateway_ids, is_binary(gateway_id) do
        PG.deliver(gateway_id, {tag, %{type: :client, id: socket.assigns.client.id}, candidates})
      end
    end

    {:noreply, socket}
  end

  defp deliver_to_gateways(socket, _gateway_ids, _tag, _candidates), do: {:noreply, socket}

  # Unauthorized targets look offline so the reply does not reveal presence.
  defp deliver_to_client(socket, target_client_id, tag, candidates) do
    candidates = PortalAPI.Sockets.limit_ice_candidates(candidates, socket.assigns.client)

    cond do
      not client_peer?(socket, target_client_id) ->
        Portal.Telemetry.ice_candidates_dropped(:client, :unauthorized, length(candidates))
        {:error, :not_found}

      candidates == [] ->
        :ok

      true ->
        PG.deliver(target_client_id, {tag, %{type: :client, id: socket.assigns.client.id}, candidates})
    end
  end

  defp client_peer?(socket, client_id) do
    Cache.Authorizations.has_client?(socket.assigns.outbound_authorizations_cache, client_id) or
      Cache.Authorizations.has_client?(socket.assigns.authorizations_cache, client_id)
  end

  defp put_outbound_authorization(socket, %{
         policy_authorization_id: policy_authorization_id,
         target_client_id: target_client_id,
         resource_id: resource_id,
         expires_at: %DateTime{} = expires_at
       }) do
    cache =
      Cache.Authorizations.put(
        socket.assigns.outbound_authorizations_cache,
        policy_authorization_id,
        target_client_id,
        resource_id,
        expires_at
      )

    assign(socket, :outbound_authorizations_cache, cache)
  end

  defp put_outbound_authorization(socket, _pending), do: socket

  defp delete_outbound_authorization(socket, %Portal.PolicyAuthorization{} = pa) do
    case Cache.Authorizations.delete(
           socket.assigns.outbound_authorizations_cache,
           pa.id,
           pa.receiving_device_id,
           pa.resource_id
         ) do
      {:ok, _expires_at_unix, cache} -> assign(socket, :outbound_authorizations_cache, cache)
      :error -> socket
    end
  end

  defmodule Database do
    import Ecto.Query, only: [from: 2, dynamic: 1]
    alias Portal.Resource.DeviceMembershipCriteria

    def x509_session_enabled?(auth_provider_id, actor_id) do
      from(auth_provider in Portal.X509.AuthProvider,
        join: actor in Portal.Actor,
        on: actor.account_id == auth_provider.account_id,
        where: auth_provider.id == ^auth_provider_id,
        where: auth_provider.is_disabled == false,
        where: actor.id == ^actor_id,
        where: actor.is_disabled == false
      )
      |> Portal.Safe.unscoped()
      |> Portal.Safe.exists?()
    end

    def fetch_device_with_actor_and_account(%Device{} = client) do
      from(device in Device,
        join: actor in Portal.Actor,
        on: actor.account_id == device.account_id and actor.id == ^client.actor_id,
        join: account in Portal.Account,
        on: account.id == device.account_id,
        where: device.account_id == ^client.account_id,
        where: device.id == ^client.id,
        select_merge: %{actor_id: actor.id, actor: actor},
        preload: [account: account]
      )
      |> Portal.Safe.unscoped()
      |> Portal.Safe.one()
    end

    def trust_anchor_certificate_exists?(account_id, ids) do
      from(c in Portal.TrustAnchorCertificate,
        where: c.account_id == ^account_id,
        where: c.id in ^ids
      )
      |> Portal.Safe.unscoped()
      |> Portal.Safe.exists?()
    end

    # Nothing else clears these when a channel stops, so a cut session would
    # otherwise leave its grants behind.
    def delete_policy_authorizations(client) do
      from(a in Portal.PolicyAuthorization,
        where: a.account_id == ^client.account_id,
        where: a.initiating_device_id == ^client.id
      )
      |> Portal.Safe.unscoped()
      |> Portal.Safe.delete_all()
    end

    def client_token_exists?(account_id, id) do
      from(t in Portal.DeviceToken, where: t.account_id == ^account_id, where: t.id == ^id)
      |> Portal.Safe.unscoped()
      |> Portal.Safe.exists?()
    end

    def certificate_revoked?(account_id, issuer, serial) do
      crl_revoked? =
        from(r in Portal.CrlRevocation,
          where: r.account_id == ^account_id,
          where: r.issuer == ^issuer,
          where: r.serial == ^serial
        )
        |> Portal.Safe.unscoped()
        |> Portal.Safe.exists?()

      crl_revoked? or
        from(s in Portal.OcspStatus,
          where: s.account_id == ^account_id,
          where: s.issuer == ^issuer,
          where: s.serial == ^serial,
          where: s.status == "revoked"
        )
        |> Portal.Safe.unscoped()
        |> Portal.Safe.exists?()
    end

    @doc """
      Fetches the device a pool may hold in the subject's account that answers at `slug`.
      Returns `{:error, :not_found}` for a miss or unauthorized read.
    """
    def get_device_by_slug(slug, subject) when is_binary(slug) do
      from(d in Portal.Device,
        as: :devices,
        where: ^DeviceMembershipCriteria.targets(),
        where: d.slug == ^slug
      )
      |> Portal.Safe.scoped(subject)
      |> Portal.Safe.one()
      |> case do
        %Portal.Device{} = device -> {:ok, device}
        _ -> {:error, :not_found}
      end
    end

    @doc """
      The DNS label of each of the device pools, derived from its name by the rules device
      slugs are made with. A pool whose name gives no label is left out.
    """
    def device_pool_labels([], _subject), do: []

    def device_pool_labels(resource_ids, subject) do
      from(r in Portal.Resource,
        where: r.id in ^resource_ids,
        select: {r.id, fragment("rtrim(left(device_slug_label(?), 63), '-')", r.name)}
      )
      |> Portal.Safe.scoped(subject)
      |> Portal.Safe.all()
      |> case do
        {:error, :unauthorized} -> []
        labels -> Enum.reject(labels, &match?({_id, ""}, &1))
      end
    end

    @doc """
      The slugs of up to `limit` devices that pools with any of these criteria hold
      when `subject` asks, most recently seen first, and how many devices they hold in all.
    """
    def member_slugs(criteria, limit, subject) do
      in_any_pool =
        Enum.reduce(criteria, dynamic(false), fn criteria, in_any_pool ->
          scope = DeviceMembershipCriteria.scope(criteria, subject)
          dynamic(^in_any_pool or ^DeviceMembershipCriteria.members(criteria, scope))
        end)

      members =
        from(d in Portal.Device, as: :devices, where: ^DeviceMembershipCriteria.targets(), where: ^in_any_pool)

      slugs =
        from(d in members,
          order_by: [desc_nulls_last: d.last_seen_at, asc: d.slug],
          limit: ^(limit + 1),
          select: d.slug
        )
        |> Portal.Safe.scoped(subject)
        |> Portal.Safe.all()
        |> case do
          {:error, :unauthorized} -> []
          slugs -> slugs
        end

      if length(slugs) > limit do
        total = members |> Portal.Safe.scoped(subject) |> Portal.Safe.aggregate(:count)

        {Enum.take(slugs, limit), total}
      else
        {slugs, length(slugs)}
      end
    end

    @doc """
      Fetches a device a pool may hold by its tunnel IPv4 or IPv6 within the subject's account.
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
              as: :devices,
              where: ^DeviceMembershipCriteria.targets(),
              where: d.ipv4 == ^inet
            )

          :ipv6 ->
            from(d in Portal.Device,
              as: :devices,
              where: ^DeviceMembershipCriteria.targets(),
              where: d.ipv6 == ^inet
            )
        end

      query
      |> Portal.Safe.scoped(subject)
      |> Portal.Safe.one()
      |> case do
        %Portal.Device{} = device -> {:ok, device}
        _ -> {:error, :not_found}
      end
    end

  end
end
