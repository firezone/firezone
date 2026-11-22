defmodule PortalAPI.Device.V1.Channel do
  @moduledoc """
  The `/device/v1` protocol: one message set for a device that reaches resources and serves
  the resources of the sites it is in.

  Peers are named by `device_id`, never by kind. The receiving side of a connection gets
  `authorize_peer` with the target the peer may reach, a resource it serves or the device
  itself through a pool, and confirms it with `peer_authorized`. The initiating side then gets
  `access_granted`. When an authorization ends, the receiving side gets `deauthorize_peer` and the
  initiating side gets `access_revoked`. `connection` says whether the pair skips ICE, or which
  ICE role a side has.

  A device that connected with a Gateway token only serves: its channel builds no client
  state, its `init` holds no resources, and every message that would start a connection is
  refused. It still accepts one as a device pool target.

  The shared client code speaks `/client/v3`; `encode/3` turns what it pushes into this protocol.
  """
  use PortalAPI, :channel
  alias PortalAPI.Channel.{Authorizations, Durability, Protocol, Relays, Session}
  alias PortalAPI.Client.Channel.Shared
  alias PortalAPI.Gateway.Views

  alias Portal.{
    Cache,
    Changes.Change,
    Device,
    PG,
    Presence,
    PubSub,
    Resource,
    SchemaHelpers,
    Site,
    SiteDevice,
    Telemetry
  }

  alias __MODULE__.Database

  require Logger

  @ice_tags [:ice_candidates, :invalidate_ice_candidates]

  @ref_salt "device_authorization_ref"
  @ref_max_age_seconds 60

  @prune_authorizations_cache_every :timer.minutes(1)

  # Like on `/gateway`, so relay credentials stay the same across reconnects.
  @relay_credentials_expire_at ~U[2038-01-01 00:00:00Z]

  @impl true
  def join("device", _payload, socket) do
    send(self(), :after_join)

    {:ok,
     assign(socket,
       channel_protocol: __MODULE__,
       served_site_ids: Database.served_site_ids(socket.assigns.client)
     )}
  end

  @impl true
  defdelegate terminate(reason, socket), to: Shared

  @impl true
  def handle_info(:after_join, %{assigns: %{subject: %{actor: %{type: :legacy_gateway}}}} = socket),
    do: serve_only_after_join(socket)

  # The sites were read at join, before the shared code subscribed to changes. Read them again so a
  # change committed in between is not lost.
  def handle_info(:after_join, socket) do
    case Shared.handle_info(:after_join, socket) do
      {:noreply, socket} ->
        if Database.served_site_ids(socket.assigns.client) == socket.assigns.served_site_ids do
          {:noreply, socket}
        else
          {:noreply, sites_served_changed(socket)}
        end

      result ->
        result
    end
  end

  def handle_info({:authorize, {initiator_pid, ref}, request}, socket) do
    if serves?(socket, request.resource) do
      authorize(socket, initiator_pid, ref, request)
    else
      # Routing read presence before this device left the site. With no reply, the initiator times out.
      {:noreply, socket}
    end
  end

  def handle_info({tag, %{type: type, id: peer_id}, candidates}, socket) when tag in @ice_tags do
    if type == :gateway or peer?(socket, peer_id) do
      push(socket, Atom.to_string(tag), %{device_id: peer_id, candidates: candidates})
    else
      Telemetry.ice_candidates_dropped(:client, :unauthorized, length(candidates))
    end

    {:noreply, socket}
  end

  # Every `/device/v1` binary handles a peer's new key, whatever version it reports.
  def handle_info({:public_key_changed, type, device_id, public_key}, socket) do
    payload =
      case type do
        :client -> %{client_id: device_id, public_key: public_key}
        :gateway -> %{gateway_id: device_id, public_key: public_key}
      end

    Protocol.push(socket, "public_key_changed", payload)
    {:noreply, socket}
  end

  def handle_info(%Change{} = change, %{assigns: %{subject: %{actor: %{type: :legacy_gateway}}}} = socket),
    do: Session.apply_change(socket, socket.assigns.client, change, &serve_only_change/2)

  # The shared handler drops a change it has seen; the device reacts only to a fresh one.
  def handle_info(%Change{lsn: lsn} = change, socket) do
    fresh? = lsn > Map.get(socket.assigns, :last_lsn, 0)

    case Shared.handle_info(change, socket) do
      {:noreply, socket} when fresh? -> {:noreply, served_change(change, socket)}
      result -> result
    end
  end

  def handle_info(message, %{assigns: %{subject: %{actor: %{type: :legacy_gateway}}}} = socket),
    do: serve_only_info(message, socket)

  def handle_info(message, socket), do: Shared.handle_info(message, socket)

  # The initiator is told only once the device echoes the ref, after it installed the authorization.
  @impl true
  def handle_in("peer_authorized", %{"ref" => signed_ref}, socket) do
    case decode_ref(socket, signed_ref) do
      {:ok, {initiator_pid, ref, rid_bytes, site_id, preshared_key, ice_credentials, use_iceless}} ->
        Authorizations.reply(initiator_pid, ref, socket.assigns.client, %{
          resource_id: Ecto.UUID.load!(rid_bytes),
          site_id: site_id && Ecto.UUID.load!(site_id),
          preshared_key: preshared_key,
          ice_credentials: ice_credentials,
          use_iceless: use_iceless
        })

        {:reply, :ok, socket}

      :error ->
        Logger.error("Device replied with an invalid ref")
        {:reply, {:error, %{reason: :invalid_ref}}, socket}
    end
  end

  def handle_in(event, %{"candidates" => candidates, "device_ids" => device_ids}, socket)
      when event in ["broadcast_ice_candidates", "broadcast_invalidated_ice_candidates"] and
             is_list(device_ids) do
    tag =
      if event == "broadcast_ice_candidates", do: :ice_candidates, else: :invalidate_ice_candidates

    device = socket.assigns.client
    candidates = PortalAPI.Sockets.limit_ice_candidates(candidates, device)

    if candidates != [] do
      peer_ids = device_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
      served = served_resource_ids(socket, peer_ids)

      for peer_id <- peer_ids do
        deliver_candidates(socket, peer_id, tag, candidates, served)
      end
    end

    {:noreply, socket}
  end

  def handle_in(event, payload, %{assigns: %{subject: %{actor: %{type: :legacy_gateway}}}} = socket),
    do: serve_only_in(event, payload, socket)

  def handle_in("request_access", payload, socket) when is_map(payload) do
    payload =
      payload
      |> Map.take(["resource_ids"])
      |> Map.put("connected_gateway_ids", Map.get(payload, "connected_device_ids", []))
      |> Map.merge(device_ip(payload["device_ip"]))

    Shared.handle_in("request_access", payload, socket)
  end

  def handle_in(event, payload, socket), do: Shared.handle_in(event, payload, socket)

  @doc false
  def protocol_version, do: 3

  @doc false
  def authorization_created_event, do: "authorization_created"

  @doc false
  def authorization_creation_failed_event, do: "authorization_creation_failed"

  @doc false
  def extend_init(socket, payload), do: Map.merge(payload, served_view(socket))

  @doc false
  def encode("init", payload, _context) do
    authorizations =
      Enum.map(payload.authorizations, fn authorization ->
        %{
          device_id: authorization.client_id,
          resource_id: authorization.resource_id,
          expires_at: authorization.expires_at
        }
      end)

    {"init", %{payload | authorizations: authorizations}}
  end

  def encode("authorization_created", payload, gateway) do
    {"access_granted",
     %{
       peer: %{
         id: payload.gateway_id,
         name: gateway.name,
         slug: gateway.slug,
         public_key: payload.gateway_public_key,
         preshared_key: payload.preshared_key,
         ipv4: payload.gateway_ipv4,
         ipv6: payload.gateway_ipv6
       },
       # A device whose version does not parse gets the legacy key; the site is the same.
       target: %{
         type: :resource,
         resource_id: payload.resource_id,
         site_id: Map.get(payload, :site_id, payload[:gateway_group_id])
       },
       local_ice_credentials: payload.client_ice_credentials,
       remote_ice_credentials: payload.gateway_ice_credentials,
       connection: connection(payload.use_iceless, :controlling),
       flow_logs_ingest_token: payload.flow_logs_ingest_token
     }}
  end

  # The receiving side is told through `authorize_peer`, so only the initiator gets this.
  def encode("client_device_access_authorized", payload, _context) do
    {"access_granted",
     %{
       peer: %{
         id: payload.client_id,
         name: payload.client_name,
         slug: payload.client_slug,
         public_key: payload.client_public_key,
         preshared_key: payload.preshared_key,
         ipv4: payload.client_ipv4,
         ipv6: payload.client_ipv6
       },
       target: %{type: :device, pool_id: payload.resource_id},
       local_ice_credentials: payload.local_ice_credentials,
       remote_ice_credentials: payload.remote_ice_credentials,
       connection: connection(payload.use_iceless, payload.ice_role),
       flow_logs_ingest_token: payload.flow_logs_ingest_token
     }}
  end

  def encode("authorization_creation_failed", payload, _context),
    do: {"access_denied", Map.put(payload, :type, :resource)}

  def encode("client_device_access_denied", payload, _context),
    do: {"access_denied", Map.put(payload, :type, :device)}

  def encode("reject_access", %{client_id: device_id, resource_id: resource_id}, :outbound),
    do: {"access_revoked", %{device_id: device_id, resource_id: resource_id}}

  def encode("reject_access", %{client_id: device_id, resource_id: resource_id}, :inbound),
    do: {"deauthorize_peer", %{device_id: device_id, resource_id: resource_id}}

  def encode("public_key_changed", %{client_id: device_id, public_key: public_key}, _context),
    do: {"public_key_changed", %{device_id: device_id, public_key: public_key}}

  def encode("public_key_changed", %{gateway_id: device_id, public_key: public_key}, _context),
    do: {"public_key_changed", %{device_id: device_id, public_key: public_key}}

  def encode("client_ice_candidate_error", %{client_id: device_id, reason: reason}, _context),
    do: {"ice_candidates_undeliverable", %{device_id: device_id, reason: reason}}

  def encode(event, payload, _context), do: {event, payload}

  @doc false
  def extend_presence_meta(_socket, meta), do: Map.put(meta, :device_v1, true)

  defp serve_only_after_join(socket) do
    device = socket.assigns.client

    # Subscribe before reading any state so no change committed after the reads is missed.
    :ok = PubSub.Changes.subscribe(device.account_id)
    account = Database.fetch_account!(device.account_id)

    if account.is_disabled do
      Session.disconnect(socket)
    else
      Process.send_after(self(), :prune_authorizations_cache, @prune_authorizations_cache_every)

      socket =
        socket
        |> assign(
          subject: %{socket.assigns.subject | account: account},
          served_site_ids: Database.served_site_ids(device),
          authorizations_cache: Cache.Gateway.hydrate(device),
          outbound_authorizations_cache: %{},
          pending_authorizations: %{}
        )
        |> serve_only_track_presence()

      with {:noreply, socket} <- serve_only_register(socket) do
        :ok = Presence.Relays.subscribe()
        relays = Relays.select(serve_only_relay_owner(socket))
        socket = Relays.cache(socket, relays)
        serve_only_init(socket, relays)

        :ok = PortalAPI.Sockets.notify_public_key_changed(device, socket.assigns[:previous_public_key])

        {:noreply, socket}
      end
    end
  end

  defp serve_only_info(:register, socket), do: serve_only_register(socket)
  defp serve_only_info(:track_presence, socket), do: {:noreply, serve_only_track_presence(socket)}

  defp serve_only_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    case Session.monitored(socket, pid) do
      :pg_scope -> serve_only_register(socket)
      :presence -> {:noreply, serve_only_track_presence(socket)}
      nil -> {:noreply, socket}
    end
  end

  defp serve_only_info({:check_relay_presence, ref}, socket),
    do: Relays.check(socket, ref, serve_only_relay_owner(socket))

  # First wins, like on `/gateway`: a connection that joins the device's group after this one is
  # told to close.
  defp serve_only_info({_ref, :join, device_id, pids}, %{assigns: %{client: %{id: device_id}}} = socket) do
    for pid <- pids, pid != self() do
      Logger.info("Disconnecting duplicate gateway connection", gateway_id: device_id)
      send(pid, :duplicate_connection)
    end

    {:noreply, socket}
  end

  defp serve_only_info(:duplicate_connection, socket), do: Session.close_transport(socket)

  defp serve_only_info(message, socket) do
    if serving_message?(message) do
      Shared.handle_info(message, socket)
    else
      {:noreply, socket}
    end
  end

  defp serving_message?(:disconnect), do: true
  defp serving_message?({:disconnect, _session_ref}), do: true
  defp serving_message?(:prune_authorizations_cache), do: true
  defp serving_message?({:reject_access, %Portal.PolicyAuthorization{}}), do: true
  defp serving_message?({:confirm_authz_durability, _authz_id}), do: true
  defp serving_message?({:confirm_session_durability, _session_ref}), do: true
  defp serving_message?({:authz_durability_timeout, _authorization, _generation}), do: true
  defp serving_message?({:session_durability_timeout, _session_ref}), do: true
  defp serving_message?(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: "presences:relays" <> _}), do: true
  defp serving_message?(_message), do: false

  defp serve_only_in("set_snownet_capabilities", payload, socket),
    do: Shared.handle_in("set_snownet_capabilities", payload, socket)

  defp serve_only_in("no_relays", payload, socket),
    do: Relays.no_relays(socket, payload, serve_only_relay_owner(socket))

  defp serve_only_in(_event, _payload, socket), do: {:reply, {:error, %{reason: :unauthorized}}, socket}

  defp serve_only_change(
         %Change{op: :update, old_struct: %Device{} = old_device, struct: %Device{id: id} = device},
         %{assigns: %{client: %{id: id} = current}} = socket
       ) do
    socket = assign(socket, :client, Device.merge_broadcast(current, device))

    cond do
      old_device.ipv4 != device.ipv4 or old_device.ipv6 != device.ipv6 ->
        relays = Relays.select(serve_only_relay_owner(socket))
        socket = Relays.cache(socket, relays)
        serve_only_init(socket, relays)
        {:noreply, serve_only_track_presence(socket)}

      old_device.config != device.config ->
        interface = PortalAPI.Client.Views.Interface.render(%{socket.assigns.client | account: socket.assigns.subject.account})
        :ok = Protocol.push(socket, "config_changed", %{interface: interface})
        {:noreply, socket}

      true ->
        {:noreply, socket}
    end
  end

  defp serve_only_change(%Change{op: :update, struct: %Portal.Account{} = account}, socket) do
    account = SchemaHelpers.merge_broadcast(socket.assigns.subject.account, account)
    {:noreply, assign(socket, :subject, %{socket.assigns.subject | account: account})}
  end

  defp serve_only_change(change, socket), do: {:noreply, served_change(change, socket)}

  # A Gateway token joins its token and device groups like on `/gateway`, so a revoke and a second
  # connection of the same gateway reach this channel. Its session goes to the gateway queue, which
  # writes no user for the device.
  defp serve_only_register(socket) do
    case Session.monitor_pg_scope(socket) do
      {:joined, socket, previous_pid} ->
        device_id = socket.assigns.client.id
        :ok = PG.join(device_id)
        :ok = PG.join(socket.assigns.token_id)
        {_ref, _members} = PG.monitor(device_id)
        serve_only_register_session(socket, previous_pid)

      result ->
        result
    end
  end

  defp serve_only_register_session(socket, nil) do
    Portal.Queue.enqueue(
      Portal.Queue.name(:gateway_session_queue),
      PortalAPI.Gateway.Channel.Shared.session_attrs(socket.assigns.client, socket.assigns.session_ref),
      metadata: %{timestamp: DateTime.utc_now()}
    )

    {:noreply, Durability.arm_session(socket)}
  end

  # A token deleted while the scope was down missed its PG disconnect.
  defp serve_only_register_session(socket, _previous_pid) do
    if Database.token_exists?(socket.assigns.client.account_id, socket.assigns.token_id) do
      {:noreply, socket}
    else
      Shared.handle_info(:disconnect, socket)
    end
  end

  defp serve_only_track_presence(socket) do
    range = socket.assigns.proto_range

    meta =
      extend_presence_meta(socket, %{
        site_ids: socket.assigns.served_site_ids,
        capabilities: [],
        proto_min: range.min,
        proto_max: range.max
      })

    Session.track_presence(socket, socket.assigns.client, socket.assigns.token_id, meta)
  end

  defp serve_only_init(socket, relays) do
    %{subject: subject, client: device} = socket.assigns

    payload = %{
      flow_logs: Shared.flow_logs_config(),
      account_slug: subject.account.slug,
      actor_name: subject.actor.name,
      resources: [],
      authorizations: PortalAPI.Client.Views.PolicyAuthorization.render_many(socket.assigns.authorizations_cache),
      relays: Relays.render(relays, serve_only_relay_owner(socket)),
      interface: PortalAPI.Client.Views.Interface.render(%{device | account: subject.account})
    }

    Protocol.push(socket, "init", extend_init(socket, payload))
  end

  defp serve_only_relay_owner(socket) do
    device = socket.assigns.client

    %{
      device: device,
      location: {device.last_seen_remote_ip_location_lat, device.last_seen_remote_ip_location_lon},
      expires_at: @relay_credentials_expire_at
    }
  end

  defp served_view(socket) do
    device = socket.assigns.client
    site_ids = socket.assigns.served_site_ids

    %{
      served_sites: device |> Database.sites(site_ids) |> Enum.map(&%{id: &1.id, name: &1.name}),
      served_resources: device |> Database.resources(site_ids) |> Enum.flat_map(&render_served_resource/1)
    }
  end

  # An admin put this device in a site or took it out of one.
  defp served_change(%Change{struct: %SiteDevice{device_id: id}}, %{assigns: %{client: %{id: id}}} = socket),
    do: sites_served_changed(socket)

  defp served_change(%Change{old_struct: %SiteDevice{device_id: id}}, %{assigns: %{client: %{id: id}}} = socket),
    do: sites_served_changed(socket)

  defp served_change(%Change{struct: %Site{id: id, name: name}, old_struct: %Site{name: old_name}}, socket)
       when name != old_name do
    if id in socket.assigns.served_site_ids do
      push(socket, "served_sites_changed", served_view(socket))
    end

    socket
  end

  defp served_change(%Change{op: :delete, old_struct: %Resource{} = resource}, socket) do
    if served?(socket, resource), do: push(socket, "served_resource_deleted", resource.id)
    socket
  end

  defp served_change(%Change{struct: %Resource{} = resource, old_struct: old_resource}, socket) do
    cond do
      served?(socket, resource) ->
        Enum.each(render_served_resource(resource), &push(socket, "served_resource_created_or_updated", &1))
        maybe_revoke_served_resource(socket, old_resource, resource)

      old_resource && served?(socket, old_resource) ->
        push(socket, "served_resource_deleted", resource.id)

      true ->
        :ok
    end

    socket
  end

  defp served_change(_change, socket), do: socket

  defp sites_served_changed(socket) do
    socket = assign(socket, :served_site_ids, Database.served_site_ids(socket.assigns.client))
    push(socket, "served_sites_changed", served_view(socket))
    send(self(), :track_presence)
    socket
  end

  defp served?(socket, %Resource{site_id: site_id}), do: site_id in socket.assigns.served_site_ids

  # A pool targets the device itself, not a site it serves.
  defp serves?(_socket, %Cache.Cacheable.Resource{type: :device_pool}), do: true

  defp serves?(socket, %Cache.Cacheable.Resource{site: %{id: site_id}}),
    do: Ecto.UUID.load!(site_id) in socket.assigns.served_site_ids

  defp serves?(_socket, _resource), do: false

  defp authorize(socket, initiator_pid, ref, request) do
    initiator = request.initiator
    device = socket.assigns.client

    {use_iceless, socket} =
      Authorizations.accept(socket, device, socket.assigns.subject.account, request)

    site_id = request.resource.site && request.resource.site.id

    ref_tuple =
      {initiator_pid, ref, request.resource.id, site_id, request.preshared_key,
       request.ice_credentials, use_iceless}

    payload = %{
      ref: encode_ref(socket, ref_tuple),
      peer: %{
        id: initiator.id,
        name: initiator.name,
        slug: initiator.slug,
        public_key: initiator.public_key,
        preshared_key: request.preshared_key,
        ipv4: initiator.ipv4,
        ipv6: initiator.ipv6
      },
      target: target(request.resource),
      local_ice_credentials: request.ice_credentials.receiver,
      remote_ice_credentials: request.ice_credentials.initiator,
      connection: connection(use_iceless, :controlled),
      expires_at: request.expires_at && DateTime.to_unix(request.expires_at, :second),
      flow_logs_ingest_token: request.responder_token
    }

    push(socket, "authorize_peer", payload)

    {:noreply, socket}
  end

  # A changed address or type cannot be applied to a peer's authorization in place, so those
  # peers are cut and authorize again. Changed filters arrive with the resource itself.
  defp maybe_revoke_served_resource(socket, %Resource{} = old, %Resource{type: type} = resource)
       when type != :device_pool do
    if old.address != resource.address or old.ip_stack != resource.ip_stack or old.type != type do
      socket.assigns.authorizations_cache
      |> Cache.Authorizations.all_pairs_for_resource(resource.id)
      |> Enum.each(fn {device_id, resource_id} ->
        push(socket, "deauthorize_peer", %{device_id: device_id, resource_id: resource_id})
      end)
    end
  end

  defp maybe_revoke_served_resource(_socket, _old, _resource), do: :ok

  # A peer that reaches a resource this device serves is told the candidates come from a gateway,
  # so a legacy client keeps its payloads. A peer that reaches this device through a pool, or that
  # this device reaches, is told they come from a client; a legacy client keys these connections
  # apart, so a peer with both gets both. A legacy client never checks a client sender, so it is
  # only sent candidates for an authorization one side holds.
  defp deliver_candidates(socket, peer_id, tag, candidates, served) do
    device = socket.assigns.client
    inbound = Cache.Authorizations.resource_ids_for_client(socket.assigns.authorizations_cache, peer_id)
    {through_served, through_pools} = Enum.split_with(inbound, &MapSet.member?(served, &1))

    as_gateway? = through_served != []

    as_client? =
      through_pools != [] or
        Cache.Authorizations.has_client?(socket.assigns.outbound_authorizations_cache, peer_id) or
        (not as_gateway? and checks_client_senders?(device.account_id, peer_id))

    if as_gateway? do
      PG.deliver(peer_id, {tag, %{type: :gateway, id: device.id}, candidates})
    end

    if as_client? do
      PG.deliver(peer_id, {tag, %{type: :client, id: device.id}, candidates})
    end

    if not as_gateway? and not as_client? do
      Telemetry.ice_candidates_dropped(:client, :unauthorized, length(candidates))
      undeliverable(socket, tag, peer_id)
    end
  end

  # The resources we serve among those the peers may reach through us, in one query per broadcast.
  defp served_resource_ids(socket, peer_ids) do
    resource_ids =
      Enum.flat_map(peer_ids, &Cache.Authorizations.resource_ids_for_client(socket.assigns.authorizations_cache, &1))

    socket.assigns.client
    |> Database.served_resource_ids(Enum.uniq(resource_ids), socket.assigns.served_site_ids)
    |> MapSet.new()
  end

  # Like on `/client`, only a peer we invalidate candidates for is reported, so the device drops it.
  defp undeliverable(socket, :invalidate_ice_candidates, peer_id),
    do: push(socket, "ice_candidates_undeliverable", %{device_id: peer_id, reason: :offline})

  defp undeliverable(_socket, _tag, _peer_id), do: :ok

  defp checks_client_senders?(account_id, peer_id) do
    case Presence.Devices.Account.get(account_id, peer_id) do
      %{metas: [meta | _]} -> meta.type == :gateway or Map.get(meta, :device_v1, false)
      _ -> false
    end
  end

  defp peer?(socket, peer_id) do
    Cache.Authorizations.has_client?(socket.assigns.authorizations_cache, peer_id) or
      Cache.Authorizations.has_client?(socket.assigns.outbound_authorizations_cache, peer_id)
  end

  defp target(%Cache.Cacheable.Resource{type: :device_pool} = resource) do
    %{
      type: :device,
      pool_id: Ecto.UUID.load!(resource.id),
      filters: Views.Resource.render_filters(resource.filters)
    }
  end

  defp target(%Cache.Cacheable.Resource{} = resource) do
    %{type: :resource, resource: Views.Resource.render(resource)}
  end

  defp connection(true, _ice_role), do: %{type: :frostlink}
  defp connection(_use_iceless, ice_role), do: %{type: :ice, role: ice_role}

  defp device_ip(nil), do: %{}

  defp device_ip(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, {_, _, _, _}} -> %{"ipv4" => ip}
      {:ok, {_, _, _, _, _, _, _, _}} -> %{"ipv6" => ip}
      {:error, _reason} -> %{}
    end
  end

  defp device_ip(_ip), do: %{}

  defp render_served_resource(%Portal.Resource{type: :device_pool}), do: []

  defp render_served_resource(%Portal.Resource{} = resource) do
    [resource |> Cache.Cacheable.to_cache() |> Views.Resource.render()]
  end

  defp encode_ref(socket, tuple) do
    ref =
      {socket.assigns.client.id, tuple}
      |> :erlang.term_to_binary()
      |> Base.url_encode64()

    Plug.Crypto.sign(socket.endpoint.config(:secret_key_base), @ref_salt, ref)
  end

  defp decode_ref(socket, signed_ref) do
    key_base = socket.endpoint.config(:secret_key_base)
    device_id = socket.assigns.client.id

    with {:ok, ref} <-
           Plug.Crypto.verify(key_base, @ref_salt, signed_ref, max_age: @ref_max_age_seconds),
         {:ok, binary} <- Base.url_decode64(ref),
         {^device_id, tuple} <- Plug.Crypto.non_executable_binary_to_term(binary, [:safe]) do
      {:ok, tuple}
    else
      _other -> :error
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def fetch_account!(id) do
      from(a in Portal.Account, where: a.id == ^id)
      |> Safe.unscoped()
      |> Safe.one!()
    end

    def token_exists?(account_id, id) do
      from(t in Portal.DeviceToken, where: t.account_id == ^account_id, where: t.id == ^id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def served_site_ids(device) do
      from(sd in Portal.SiteDevice,
        where: sd.account_id == ^device.account_id and sd.device_id == ^device.id,
        order_by: sd.site_id,
        select: sd.site_id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def sites(_device, []), do: []

    def sites(device, site_ids) do
      from(s in Portal.Site,
        where: s.account_id == ^device.account_id and s.id in ^site_ids,
        order_by: s.name
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def served_resource_ids(_device, [], _site_ids), do: []
    def served_resource_ids(_device, _resource_ids, []), do: []

    def served_resource_ids(device, resource_ids, site_ids) do
      from(r in Portal.Resource,
        where:
          r.account_id == ^device.account_id and r.id in ^resource_ids and
            r.site_id in ^site_ids and r.type != :device_pool,
        select: r.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def resources(_device, []), do: []

    def resources(device, site_ids) do
      from(r in Portal.Resource,
        where: r.account_id == ^device.account_id and r.site_id in ^site_ids,
        order_by: r.name
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
