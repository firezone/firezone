defmodule PortalAPI.Device.Channel.Core do
  @moduledoc """
  The channel every device talks to the portal through.

  A device connects over a socket whose channel module is an adapter
  implementing `PortalAPI.Device.Channel.Protocol`; the adapter renames what
  its deployed binaries expect and delegates everything else here. The core
  joins the device, registers it for cluster-wide delivery, tracks its
  presence, hands it relays, applies the account's row changes, and runs the
  two halves of its state: `PortalAPI.Device.Channel.Outbound`, the
  resources it may reach, and `PortalAPI.Device.Channel.Inbound`, what it
  serves to others.

  The device lives under the `:device` assign. A protocol that arrived with
  the device under an older name keeps it there too, so nothing written
  against that name reads a stale struct.
  """

  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 3]

  alias Portal.{Account, PG, Presence, PubSub}
  alias Portal.Authentication
  alias Portal.Authentication.Credential
  alias PortalAPI.Device.Channel.{Changes, DeviceDomains, Durability, Ice, Inbound, Outbound, Relays}
  alias __MODULE__.Database

  require Logger

  # Relay credentials must be stable across reconnects so that a device that
  # stays connected for months does not see them change on every reconnect.
  # A fixed far-future date rather than an offset from now.
  @relay_credentials_expire_at ~U[2038-01-01 00:00:00Z]

  @doc false
  defdelegate policy_authorization_queue_opts(), to: Outbound

  @doc """
  Self-heal escape hatch. Pushes `reject_access` to a device's data plane for
  the given `(client_id, resource_id)` pair and clears the matching local
  cache entries.

  Every natural production path that ends in `reject_access` goes through
  `PortalAPI.Device.Channel.Inbound.revoke/2` first, which evicts the cached
  authorization by id and pushes reject: a replicated delete of the row, the
  queue's failure callback, or the receiver's durability timer. In every one
  of those, reject reaches connlib only when the authorization truly no
  longer exists. The synthetic case this function produces, "reject a pair
  the database still authorizes", has no natural production trigger.

  It exists because the durability timer is the fail-closed guarantee: if a
  queue crashes before flushing, the cached authorization on the receiver
  eventually triggers a reject, the receiver answers the initiator's packets
  with a `no_authorization` control event, and the initiator asks for a fresh
  authorization through the normal path. This is the manual version of that
  signal, for when the local cache ever desyncs from production state.
  Integration tests use it to exercise the recovery end to end.

  Do not call from production code paths.
  """
  def revoke_pair_access(device_id, client_id, resource_id) do
    PG.deliver(device_id, {:revoke_pair_access, client_id, resource_id})
  end

  ####################################
  ##### Reading the socket ###########
  ####################################

  @doc "The channel protocol module, an adapter implementing `PortalAPI.Device.Channel.Protocol`."
  @spec protocol(Phoenix.Socket.t()) :: module()
  def protocol(socket), do: socket.assigns.channel_protocol

  @doc "The protocol version the device speaks."
  @spec protocol_version(Phoenix.Socket.t()) :: pos_integer()
  def protocol_version(socket), do: protocol(socket).protocol_version()

  @doc "Whether the device consumes resources on this protocol."
  @spec outbound?(Phoenix.Socket.t()) :: boolean()
  def outbound?(socket), do: protocol(socket).outbound?()

  @doc """
  The device this channel serves. Read under the name the protocol arrived
  with, since that is the assign anything outside the core still writes.
  """
  @spec device(Phoenix.Socket.t()) :: Portal.Device.t()
  def device(socket), do: socket.assigns[protocol(socket).device_key()] || socket.assigns.device

  @doc "Stores the device, under `:device` and under the name the protocol arrived with."
  @spec put_device(Phoenix.Socket.t(), Portal.Device.t()) :: Phoenix.Socket.t()
  def put_device(socket, device) do
    socket = assign(socket, :device, device)

    case protocol(socket).device_key() do
      :device -> socket
      key -> assign(socket, key, device)
    end
  end

  @doc """
  The device's account as the channel currently knows it. A gateway re-reads
  it on join, since its subject is built from a token; a client's travels
  with its subject.
  """
  @spec account(Phoenix.Socket.t()) :: Account.t()
  def account(socket), do: socket.assigns[:account] || socket.assigns.subject.account

  @doc "Stores a changed account where `account/1` finds it, and on the subject."
  @spec put_account(Phoenix.Socket.t(), Account.t()) :: Phoenix.Socket.t()
  def put_account(socket, account) do
    subject = %{socket.assigns.subject | account: account}
    socket = assign(socket, :subject, subject)

    if Map.has_key?(socket.assigns, :account), do: assign(socket, :account, account), else: socket
  end

  ####################################
  ##### Channel lifecycle ############
  ####################################

  @doc "Joins the device; the work happens in `:after_join` once the join replied."
  def join(_topic, _payload, socket) do
    device = socket.assigns[protocol(socket).device_key()]

    send(self(), :after_join)

    {:ok, assign(socket, :device, device)}
  end

  @doc """
  On an abnormal exit, drains the whole WebSocket instead of just letting
  the channel die. connlib ignores `phx_error` and would keep the transport
  alive, re-joining reactively and reusing the transport-scoped session_ref,
  whose earlier flush confirmation could cancel the new session's durability
  timer. Draining forces a full reconnect that re-runs `connect/3` and mints
  a fresh session_ref, keeping transport and session one to one. Graceful
  stops already send `phx_close`.
  """
  def terminate(reason, socket) do
    if abnormal_exit?(reason) do
      send(socket.transport_pid, :socket_drain)
    end

    :ok
  end

  defp abnormal_exit?(:normal), do: false
  defp abnormal_exit?(:shutdown), do: false
  defp abnormal_exit?({:shutdown, _reason}), do: false
  defp abnormal_exit?(_reason), do: true

  defp after_join(socket) do
    if outbound?(socket), do: schedule_session_expiry(socket.assigns.subject.expires_at)

    {socket, resources} =
      if outbound?(socket), do: Outbound.hydrate(socket), else: {socket, []}

    socket = Inbound.hydrate(socket)

    {socket, relays} = Relays.subscribe_and_select(socket, relay_peer(socket))

    socket = track_presence(socket)

    :ok = PubSub.Changes.subscribe(device(socket).account_id)

    {:noreply, socket} = register(socket)

    # A gateway's subject is built from its token; the account's slug and
    # config can change while it stays connected, so the row is re-read.
    socket =
      if outbound?(socket),
        do: socket,
        else: assign(socket, :account, Database.fetch_account!(socket.assigns.subject))

    init(socket, resources, relays)

    {:noreply, socket}
  end

  defp schedule_session_expiry(nil), do: :ok

  defp schedule_session_expiry(expires_at) do
    ms = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    Process.send_after(self(), :disconnect, max(ms, 0))
  end

  ####################################
  ##### Init #########################
  ####################################

  defp init(socket, resources, relays) do
    device = device(socket)
    account = account(socket)

    payload = %{
      flow_logs: flow_logs_config(),
      account_slug: account.slug,
      authorizations: PortalAPI.Device.Views.Authorization.render_many(socket.assigns.inbound),
      relays: Relays.render(relays, relay_peer(socket))
    }

    payload =
      if outbound?(socket) do
        Map.merge(payload, %{
          actor_name: socket.assigns.subject.actor.name,
          resources: Outbound.render_resources(socket, resources),
          interface: PortalAPI.Client.Views.Interface.render(%{device | account: account})
        })
      else
        Map.merge(payload, %{
          interface: PortalAPI.Gateway.Views.Interface.render(device),
          # Not used, but part of the payload the Gateway parses.
          config: %{ipv4_masquerade_enabled: true, ipv6_masquerade_enabled: true}
        })
      end

    push(socket, "init", payload)
  end

  defp flow_logs_config do
    %{
      api_url: Portal.Config.fetch_env!(:portal, :flow_logs_api_url),
      upload_interval_secs: Portal.Config.fetch_env!(:portal, :flow_logs_upload_interval_secs),
      upload_batch_size: Portal.Config.fetch_env!(:portal, :flow_logs_upload_batch_size)
    }
  end

  @doc "Sends init again with fresh relays, after something it carried changed."
  @spec reinitialize(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def reinitialize(socket) do
    {socket, relays} = Relays.select(socket, relay_peer(socket))

    resources =
      if outbound?(socket), do: socket.assigns.cache.connectable_resources, else: []

    init(socket, resources, relays)

    if outbound?(socket), do: track_presence(socket), else: socket
  end

  ####################################
  ##### Registration and presence ####
  ####################################

  # Registers the channel for cluster-wide delivery and persists the session
  # once. Re-registrations after a PG scope crash share the same channel and
  # session row, so they neither enqueue nor arm again.
  defp register(socket) do
    current_pid = socket.assigns[:pg_scope_pid]
    device = device(socket)

    case PG.scope_pid() do
      nil ->
        Logger.error("Portal.PG scope is not running, retrying registration shortly")
        Process.send_after(self(), :register, 50)
        {:noreply, socket}

      ^current_pid ->
        {:noreply, socket}

      new_pid ->
        Process.monitor(new_pid)

        case protocol(socket).registration() do
          :last_wins ->
            # Any earlier channel for the device is told to disconnect.
            :ok = PG.register(device.id)

          :first_wins ->
            # Deployed gateways exit for good on any `disconnect`, so the
            # channel that was here first stays and newcomers are cut: the
            # device's group is watched and anyone joining later is told to
            # go. Monitors die with the scope, so this re-arms every time.
            :ok = PG.join(device.id)
            {_ref, _members} = PG.monitor(device.id)
        end

        :ok = PG.join(token_id(socket))
        if device.actor_id, do: :ok = PG.join(device.actor_id)

        socket = assign(socket, :pg_scope_pid, new_pid)

        # The account's replication subscription is already active. Checking
        # current state after subscribing closes the connect race: an earlier
        # disable is seen here, a later one arrives through the broadcast.
        if x509_session_enabled?(socket) do
          register_session(socket, current_pid)
        else
          disconnect(socket)
        end
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

  defp register_session(socket, current_pid) do
    if is_nil(current_pid) do
      {queue, attrs} = session_entry(socket)

      Portal.Queue.enqueue(queue, attrs,
        metadata: %{
          subject: Authentication.Subject.to_map(socket.assigns.subject),
          timestamp: DateTime.utc_now()
        }
      )

      {:noreply, Durability.arm_session(socket)}
    else
      {:noreply, socket}
    end
  end

  # Where this session is written and what is written: a client's session
  # carries the identifiers and the attestation this connect proved, a
  # gateway's only the connection itself.
  defp session_entry(socket) do
    device = device(socket)
    session_ref = socket.assigns.session_ref

    case protocol(socket).kind() do
      :gateway -> {:gateway_session_queue, gateway_session_attrs(device, session_ref)}
      _client_or_device -> {:client_session_queue, client_session_attrs(device, session_ref)}
    end
  end

  defp gateway_session_attrs(%Portal.Device{} = gateway, session_ref) do
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

  defp client_session_attrs(%Portal.Device{} = client, session_ref) do
    # The attested snapshot is carried only when THIS session proved
    # possession. Copying it off the row for every session would re-assert a
    # stale snapshot and race a fresher proof flushing from another session;
    # the flush's recency guard keeps the row's values when the entry carries
    # none.
    attested_attrs =
      if client.attested? do
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

  @doc """
  Tracks the device's presence and monitors the tracker's shard processes so
  it is re-tracked if any crash. Monitoring the supervisor alone is not
  enough: a shard crashing under `:one_for_one` does not take it down.
  """
  @spec track_presence(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def track_presence(socket) do
    case Process.whereis(Portal.Presence) do
      nil ->
        Process.send_after(self(), :track_presence, 50)
        socket

      sup_pid ->
        # The sites the device serves travel in its presence meta, so the
        # assignments are read once, at connect.
        device = preload_site_devices(device(socket))
        socket = put_device(socket, device)

        # Pool authorization reads a target's groups off its presence, so
        # they follow its memberships.
        :ok = Presence.Devices.connect(device, token_id(socket), %{group_ids: Outbound.group_ids(socket)})

        for {_pid, ref} <- socket.assigns[:presence_monitors] || [] do
          Process.demonitor(ref, [:flush])
        end

        monitors =
          for {_, pid, _, _} <- Supervisor.which_children(sup_pid), is_pid(pid) do
            {pid, Process.monitor(pid)}
          end

        assign(socket, :presence_monitors, monitors)
    end
  end

  defp preload_site_devices(%Portal.Device{site_devices: %Ecto.Association.NotLoaded{}} = device) do
    Database.preload_site_devices(device)
  end

  defp preload_site_devices(%Portal.Device{} = device), do: device

  defp token_id(socket), do: socket.assigns[:token_id] || socket.assigns.subject.credential.id

  ####################################
  ##### Disconnecting ################
  ####################################

  @doc "Tells the device its token expired and stops; the device must sign in again."
  @spec disconnect(Phoenix.Socket.t()) :: {:stop, :shutdown, Phoenix.Socket.t()}
  def disconnect(socket) do
    # Pushed before the socket closes so the device does not reconnect at once.
    push(socket, "disconnect", %{reason: "token_expired"})
    {:stop, :shutdown, socket}
  end

  @doc """
  Cuts a device whose account went away. A channel stop alone can leave the
  transport available for a reactive rejoin, which would bypass `connect/3`
  and its account check, so the transport is drained too.
  """
  @spec disconnect_account(Phoenix.Socket.t()) :: {:stop, :shutdown, Phoenix.Socket.t()}
  def disconnect_account(socket) do
    send(socket.transport_pid, :socket_drain)
    disconnect(socket)
  end

  # A CA revoked a certificate. The session is only cut if it is the one this
  # connection presented: the device columns the sync job matched on record
  # the last certificate a device ever showed, so a device that attested once
  # and has since been connecting without a certificate would otherwise be
  # dropped over a certificate it is not using. Its authorizations go too,
  # since nothing else clears them when a channel stops. The reason is its
  # own rather than "token_expired": the token is fine, and a device that
  # knows the difference can say so instead of reporting a sign-in problem.
  defp certificate_revoked(socket, issuer, serial) do
    device = device(socket)

    if socket.assigns[:attestation] == %{issuer: issuer, serial: serial} do
      Logger.info("Disconnecting device: its certificate was revoked",
        account_id: device.account_id,
        device_id: device.id,
        cert_serial: serial
      )

      Database.delete_policy_authorizations(device)
      push(socket, "disconnect", %{reason: "certificate_revoked"})

      # Stopping the channel alone leaves the transport up, and a device may
      # rejoin on it without running connect/3 again, which is where the
      # revoked certificate would be refused.
      send(socket.transport_pid, :socket_drain)
      {:stop, :shutdown, socket}
    else
      {:noreply, socket}
    end
  end

  ####################################
  ##### Messages from the portal #####
  ####################################

  @doc "Handles every message a device channel receives from the portal."
  def handle_info(:after_join, socket), do: after_join(socket)

  def handle_info(%Portal.Changes.Change{} = change, socket), do: Changes.handle(change, socket)

  def handle_info(:recompute_authorized_resources, socket), do: Outbound.recompute(socket)

  def handle_info(prune, socket) when prune in [:prune_inbound, :prune_cache, :prune_authorizations_cache] do
    {:noreply, Inbound.prune(socket)}
  end

  # Relay presence changes are debounced: the check runs after the last of a burst.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: "presences:relays" <> _}, socket) do
    Relays.handle_presence_diff(socket)
  end

  def handle_info({:check_relay_presence, ref}, socket) do
    Relays.handle_presence_check(socket, ref, relay_peer(socket))
  end

  # Candidates relayed from a peer; the key names the peer as this device knows it.
  def handle_info({:ice_candidates, peer_id, candidates}, socket) do
    Ice.push_candidates(socket, "ice_candidates", peer_key(socket), peer_id, candidates)
  end

  def handle_info({:invalidate_ice_candidates, peer_id, candidates}, socket) do
    Ice.push_candidates(socket, "invalidate_ice_candidates", peer_key(socket), peer_id, candidates)
  end

  def handle_info({:client_ice_candidates, client_id, candidates}, socket) do
    Ice.push_candidates(socket, "client_ice_candidates", :client_id, client_id, candidates)
  end

  def handle_info({:invalidate_client_ice_candidates, client_id, candidates}, socket) do
    Ice.push_candidates(socket, "invalidate_client_ice_candidates", :client_id, client_id, candidates)
  end

  # Authorizations this device receives.
  def handle_info({:create_authorization, reply_to, payload}, socket) do
    Inbound.create_authorization(socket, reply_to, payload)
  end

  def handle_info({:client_device_access_authorized, reply_to, payload}, socket) do
    Inbound.client_device_access_authorized(socket, reply_to, payload)
  end

  # DEPRECATED IN 1.4
  def handle_info({:allow_access, reply_to, attrs}, socket), do: Inbound.allow_access(socket, reply_to, attrs)

  # DEPRECATED IN 1.4
  def handle_info({:request_connection, reply_to, attrs}, socket) do
    Inbound.request_connection(socket, reply_to, attrs)
  end

  # Replies to authorizations this device asked for.

  # DEPRECATED IN 1.4
  def handle_info({:connect, socket_ref, rid_bytes, gateway_public_key, payload}, socket) do
    Outbound.legacy_connect(socket, socket_ref, rid_bytes, gateway_public_key, payload)
  end

  # Tolerates the pre-snownet-capabilities tuple from older portal nodes
  # during a rolling deploy, with `use_iceless` defaulting to false.
  def handle_info(
        {:connect, socket_ref, rid_bytes, site_id, gateway_id, gateway_public_key, gateway_ipv4,
         gateway_ipv6, preshared_key, ice_credentials},
        socket
      ) do
    handle_info(
      {:connect, socket_ref, rid_bytes, site_id, gateway_id, gateway_public_key, gateway_ipv4,
       gateway_ipv6, preshared_key, ice_credentials, false},
      socket
    )
  end

  def handle_info(
        {:connect, _socket_ref, rid_bytes, site_id, gateway_id, gateway_public_key, gateway_ipv4,
         gateway_ipv6, preshared_key, ice_credentials, use_iceless},
        socket
      ) do
    Outbound.connect(
      socket,
      rid_bytes,
      site_id,
      gateway_id,
      gateway_public_key,
      gateway_ipv4,
      gateway_ipv6,
      preshared_key,
      ice_credentials,
      use_iceless
    )
  end

  def handle_info({:authorization_creation_timeout, resource_id, generation}, socket) do
    Outbound.authorization_timed_out(socket, resource_id, generation)
  end

  def handle_info({:authorization_creation_timeout, ref}, socket) do
    Outbound.device_access_timed_out(socket, ref)
  end

  def handle_info({:device_access_acked, ref, use_iceless, client_name, client_slug}, socket) do
    Outbound.device_access_acked(socket, ref, use_iceless, client_name, client_slug)
  end

  def handle_info({:device_access_denied, payload, reason}, socket) do
    Outbound.push_denied(socket, payload, reason)
  end

  def handle_info({:device_domain_resolution_failed, domain, reason}, socket) do
    push(socket, "device_domain_resolution_failed", %{domain: domain, reason: reason})
    {:noreply, socket}
  end

  def handle_info({:device_domain_browse_failed, domain}, socket) do
    push(socket, "device_domain_browse_failed", %{domain: domain, reason: :not_found})
    {:noreply, socket}
  end

  # Revocation, from the queue's failure callback, the operator's hand, and
  # the durability timers.
  def handle_info({:reject_access, %Portal.PolicyAuthorization{} = pa}, socket) do
    Inbound.reject_access(socket, pa)
  end

  def handle_info({:revoke_pair_access, client_id, resource_id}, socket) do
    Inbound.revoke_pair(socket, client_id, resource_id)
  end

  def handle_info({:confirm_authz_durability, authz_id}, socket) do
    {:noreply, Durability.confirm_authorization(socket, authz_id)}
  end

  def handle_info({:confirm_session_durability, session_ref}, socket) do
    {:noreply, Durability.confirm_session(socket, session_ref)}
  end

  def handle_info({:authz_durability_timeout, %Portal.PolicyAuthorization{} = pa, generation}, socket) do
    case Durability.authorization_timed_out(socket, pa, generation) do
      {:timed_out, socket} -> Inbound.revoke(socket, pa)
      :stale -> {:noreply, socket}
    end
  end

  def handle_info({:session_durability_timeout, session_ref}, socket) do
    if Durability.session_expired?(socket, session_ref) do
      Logger.warning("Session #{inspect(session_ref)} was not confirmed durable; disconnecting")

      # Not "token_expired", which would tear down the device's state; the
      # device reconnects and the session is written again.
      {:stop, :shutdown, socket}
    else
      {:noreply, socket}
    end
  end

  # Disconnects.
  def handle_info(:disconnect, socket), do: disconnect(socket)

  # Flush-failure disconnects are delivered by device id but target one
  # session; a mismatched ref belongs to a predecessor channel and falls
  # through to the catch-all.
  def handle_info({:disconnect, session_ref}, socket)
      when session_ref == socket.assigns.session_ref do
    disconnect(socket)
  end

  def handle_info({:certificate_revoked, issuer, serial}, socket) do
    certificate_revoked(socket, issuer, serial)
  end

  # Another channel joined this device's group on a first-wins protocol: a
  # duplicate connection raced past the connect-time check, and the newcomers
  # are told to go. Two simultaneous cross-node joins can each boot the other,
  # but reconnect backoff jitter settles that within a round or two.
  def handle_info({_ref, :join, device_id, pids}, %{assigns: %{device: %{id: device_id}}} = socket) do
    for pid <- pids, pid != self() do
      Logger.info("Disconnecting duplicate device connection", device_id: device_id)
      send(pid, :disconnect)
    end

    {:noreply, socket}
  end

  def handle_info({_ref, :leave, device_id, _pids}, %{assigns: %{device: %{id: device_id}}} = socket) do
    {:noreply, socket}
  end

  # A monitored process crashed: whichever subsystem it belonged to is recovered.
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

  def handle_info(:register, socket), do: register(socket)

  def handle_info(:track_presence, socket), do: {:noreply, track_presence(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ####################################
  ##### Messages from the device #####
  ####################################

  @doc """
  Handles a message from the device, under the core's name for it. Adapters
  rename what their protocol calls it before delegating here.
  """
  def handle_in("request_authorization", %{"resource_id" => _} = payload, socket) do
    if outbound?(socket), do: Outbound.request_authorization(socket, payload), else: unknown(socket, "request_authorization", payload)
  end

  def handle_in("request_access", payload, socket) do
    if outbound?(socket) and protocol_version(socket) >= 3 do
      Outbound.request_access(socket, payload)
    else
      {:noreply, socket}
    end
  end

  # Some clients send these sporadically by accident, since any packet with a
  # destination in 100.64.0.0/10 triggers it in certain older clients. The
  # message was introduced for the proof of concept of client-to-client and
  # replaced by the standard authorization request.
  def handle_in("request_device_access", _payload, socket), do: {:noreply, socket}

  def handle_in("resolve_device_domain", %{"domain" => domain}, socket) when is_binary(domain) do
    if outbound?(socket), do: DeviceDomains.resolve(socket, domain), else: {:noreply, socket}
  end

  def handle_in("browse_device_domain", %{"domain" => domain}, socket) when is_binary(domain) do
    if outbound?(socket), do: DeviceDomains.browse(socket, domain), else: {:noreply, socket}
  end

  # DEPRECATED IN 1.4
  def handle_in("prepare_connection", %{"resource_id" => _} = attrs, socket) do
    if outbound?(socket), do: Outbound.prepare_connection(socket, attrs), else: unknown(socket, "prepare_connection", attrs)
  end

  # DEPRECATED IN 1.4
  def handle_in("reuse_connection", %{"gateway_id" => _, "resource_id" => _, "payload" => _} = attrs, socket) do
    if outbound?(socket), do: Outbound.reuse_connection(socket, attrs), else: unknown(socket, "reuse_connection", attrs)
  end

  # DEPRECATED IN 1.4
  def handle_in(
        "request_connection",
        %{"gateway_id" => _, "resource_id" => _, "client_payload" => _, "client_preshared_key" => _} = attrs,
        socket
      ) do
    if outbound?(socket), do: Outbound.request_connection(socket, attrs), else: unknown(socket, "request_connection", attrs)
  end

  # The device echoes the signed ref of an authorization it installed.
  def handle_in("authorization_created", %{"ref" => signed_ref}, socket) do
    Inbound.authorization_created(socket, signed_ref)
  end

  # DEPRECATED IN 1.4
  def handle_in("connection_ready", %{"ref" => signed_ref, "gateway_payload" => payload}, socket) do
    Inbound.connection_ready(socket, signed_ref, payload)
  end

  # ICE candidates for peers, named by whichever key the device's protocol uses.
  def handle_in("broadcast_ice_candidates", %{"candidates" => candidates} = payload, socket) do
    :ok = Ice.broadcast(peer_ids(payload), :ice_candidates, device(socket).id, candidates)
    {:noreply, socket}
  end

  def handle_in("broadcast_invalidated_ice_candidates", %{"candidates" => candidates} = payload, socket) do
    :ok = Ice.broadcast(peer_ids(payload), :invalidate_ice_candidates, device(socket).id, candidates)
    {:noreply, socket}
  end

  def handle_in("new_gateway_ice_candidates", %{"candidates" => candidates, "gateway_id" => target}, socket) do
    _ = Ice.deliver(target, :ice_candidates, device(socket).id, candidates)
    {:noreply, socket}
  end

  def handle_in("invalidate_gateway_ice_candidates", %{"candidates" => candidates, "gateway_id" => target}, socket) do
    _ = Ice.deliver(target, :invalidate_ice_candidates, device(socket).id, candidates)
    {:noreply, socket}
  end

  def handle_in("new_client_ice_candidates", %{"candidates" => candidates, "client_id" => target}, socket) do
    _ = Ice.deliver(target, :client_ice_candidates, device(socket).id, candidates)
    {:noreply, socket}
  end

  def handle_in("invalidate_client_ice_candidates", %{"candidates" => candidates, "client_id" => target}, socket) do
    case Ice.deliver(target, :invalidate_client_ice_candidates, device(socket).id, candidates) do
      :ok ->
        {:noreply, socket}

      {:error, :not_found} ->
        push(socket, "client_ice_candidate_error", %{client_id: target, reason: :offline})
        {:noreply, socket}
    end
  end

  def handle_in("set_snownet_capabilities", payload, socket) when is_map(payload) do
    {:noreply, assign(socket, :iceless_capable, payload["iceless"] == true)}
  end

  def handle_in("no_relays", payload, socket) do
    Relays.handle_no_relays(socket, payload, relay_peer(socket))
  end

  def handle_in(message, payload, socket), do: unknown(socket, message, payload)

  @doc "Refuses a message the protocol does not know."
  def unknown(socket, message, payload) do
    Logger.error("Unknown device message",
      message: message,
      payload: payload,
      subject: Map.get(socket.assigns, :subject),
      device: Map.get(socket.assigns, :device)
    )

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  ####################################
  ##### Helpers ######################
  ####################################

  # Which peers a candidate broadcast names: a client lists gateways, a
  # gateway lists clients, a device on the unified protocol lists devices.
  defp peer_ids(payload) do
    payload["device_ids"] || payload["gateway_ids"] || payload["client_ids"] || []
  end

  # How a peer is named in a candidate payload pushed to this device.
  defp peer_key(socket) do
    case protocol(socket).kind() do
      :client -> :gateway_id
      :gateway -> :client_id
      :device -> :device_id
    end
  end

  # The device as relay selection sees it. A gateway's TURN credentials carry
  # the far future expiry; a client's last as long as its session.
  defp relay_peer(socket) do
    device = device(socket)

    {location, expires_at} =
      if outbound?(socket) do
        {{
           socket.assigns.subject.context.remote_ip_location_lat,
           socket.assigns.subject.context.remote_ip_location_lon
         }, socket.assigns.subject.expires_at || @relay_credentials_expire_at}
      else
        {{device.last_seen_remote_ip_location_lat, device.last_seen_remote_ip_location_lon},
         @relay_credentials_expire_at}
      end

    %{
      location: location,
      public_key: device.public_key,
      credentials_expire_at: expires_at,
      account_id: device.account_id
    }
  end

  defmodule Database do
    @moduledoc false
    import Ecto.Query, only: [from: 2, dynamic: 1]

    # Re-read rather than taken from the subject: the account's slug and
    # config can change while the device stays connected.
    def fetch_account!(subject) do
      from(a in Portal.Account, where: a.id == ^subject.account.id)
      |> Portal.Safe.scoped(subject)
      |> Portal.Safe.one!()
    end

    def preload_site_devices(%Portal.Device{} = device) do
      Portal.Safe.preload(device, :site_devices)
    end

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

    # Nothing else clears these when a channel stops, so a cut session would
    # otherwise leave its grants behind.
    def delete_policy_authorizations(device) do
      from(a in Portal.PolicyAuthorization,
        where: a.account_id == ^device.account_id,
        where: a.initiating_device_id == ^device.id
      )
      |> Portal.Safe.unscoped()
      |> Portal.Safe.delete_all()
    end

    @doc """
    Fetches the client device in the subject's account that answers at `slug`.
    Returns `{:error, :not_found}` for a miss or unauthorized read.
    """
    def get_device_by_slug(slug, subject) when is_binary(slug) do
      from(d in Portal.Device,
        where: d.type == :client,
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
    The DNS label of each of the device pools, derived from its name by the
    rules device slugs are made with. A pool whose name gives no label is
    left out.
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
    The slugs of up to `limit` client devices that pools with any of these
    criteria hold when `subject` asks, most recently seen first, and how many
    devices they hold in all.
    """
    def member_slugs(criteria, limit, subject) do
      in_any_pool =
        Enum.reduce(criteria, dynamic(false), fn criteria, in_any_pool ->
          scope = Portal.Resource.DeviceMembershipCriteria.scope(criteria, subject)
          dynamic(^in_any_pool or ^Portal.Resource.DeviceMembershipCriteria.members(criteria, scope))
        end)

      members = from(d in Portal.Device, as: :devices, where: d.type == :client, where: ^in_any_pool)

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

    @doc "Fetches a client device by its tunnel IPv4 or IPv6 within the subject's account."
    def get_device_by_address({:ipv4, ipv4_tuple}, subject) do
      fetch_device_by_inet(:ipv4, %Postgrex.INET{address: ipv4_tuple}, subject)
    end

    def get_device_by_address({:ipv6, ipv6_tuple}, subject) do
      fetch_device_by_inet(:ipv6, %Postgrex.INET{address: ipv6_tuple}, subject)
    end

    defp fetch_device_by_inet(family, %Postgrex.INET{} = inet, subject) do
      query =
        case family do
          :ipv4 -> from(d in Portal.Device, where: d.type == :client, where: d.ipv4 == ^inet)
          :ipv6 -> from(d in Portal.Device, where: d.type == :client, where: d.ipv6 == ^inet)
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
