defmodule PortalAPI.Device.V1.Channel do
  @moduledoc """
  The `/device/v1` protocol: what a client gets on `/client/v3`, plus what a device needs to
  serve the resources of the site it is in.

  Init also carries `sites_served` and `local_resources`. Every authorization this device
  receives arrives as `create_authorization`, with a `target` of a resource it serves or of the
  device itself through a pool, and the device echoes the signed `ref` once it installed it.
  ICE candidates name the peer by `device_id` in both directions.
  """
  use PortalAPI, :channel
  alias PortalAPI.Channel.Authorizations
  alias PortalAPI.Client.Channel.Shared
  alias PortalAPI.Gateway.Views
  alias Portal.{Cache, Changes.Change, PG, Presence, Resource, SiteDevice, Telemetry}
  alias __MODULE__.Database

  require Logger

  @ice_tags [:ice_candidates, :invalidate_ice_candidates]

  @ref_salt "device_authorization_ref"
  @ref_max_age_seconds 60

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
  def handle_info({:authorize, {initiator_pid, ref}, request}, socket) do
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
      target: target(request.resource),
      client: %{
        id: initiator.id,
        name: initiator.name,
        slug: initiator.slug,
        public_key: initiator.public_key,
        preshared_key: request.preshared_key,
        ipv4: initiator.ipv4,
        ipv6: initiator.ipv6
      },
      client_ice_credentials: request.ice_credentials.initiator,
      gateway_ice_credentials: request.ice_credentials.receiver,
      resource: served_resource(request.resource),
      expires_at: request.expires_at && DateTime.to_unix(request.expires_at, :second),
      use_iceless: use_iceless,
      ice_role: :controlled,
      flow_logs_ingest_token: request.responder_token
    }

    push(socket, "create_authorization", payload)

    {:noreply, socket}
  end

  def handle_info({tag, %{type: type, id: peer_id}, candidates}, socket) when tag in @ice_tags do
    if type == :gateway or peer?(socket, peer_id) do
      push(socket, Atom.to_string(tag), %{device_id: peer_id, candidates: candidates})
    else
      Telemetry.ice_candidates_dropped(:client, :unauthorized, length(candidates))
    end

    {:noreply, socket}
  end

  # The shared handler drops a change it has seen; the device reacts only to a fresh one.
  def handle_info(%Change{lsn: lsn} = change, socket) do
    fresh? = lsn > Map.get(socket.assigns, :last_lsn, 0)

    case Shared.handle_info(change, socket) do
      {:noreply, socket} when fresh? -> {:noreply, served_change(change, socket)}
      result -> result
    end
  end

  def handle_info(message, socket), do: Shared.handle_info(message, socket)

  # The initiator is told only once the device echoes the ref, after it installed the authorization.
  @impl true
  def handle_in("authorization_created", %{"ref" => signed_ref}, socket) do
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
      for peer_id <- Enum.uniq(device_ids), is_binary(peer_id) do
        deliver_candidates(socket, peer_id, tag, candidates)
      end
    end

    {:noreply, socket}
  end

  def handle_in("set_capabilities", payload, socket) when is_map(payload) do
    {:noreply, assign(socket, :iceless_capable, payload["iceless"] == true)}
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
  def extend_presence_meta(_socket, meta), do: Map.put(meta, :device_v1, true)

  defp served_view(socket) do
    device = socket.assigns.client
    site_ids = socket.assigns.served_site_ids

    %{
      sites_served: device |> Database.sites(site_ids) |> Enum.map(&%{id: &1.id, name: &1.name}),
      local_resources: device |> Database.resources(site_ids) |> Enum.flat_map(&render_local_resource/1)
    }
  end

  # An admin put this device in a site or took it out of one.
  defp served_change(%Change{struct: %SiteDevice{device_id: id}}, %{assigns: %{client: %{id: id}}} = socket),
    do: sites_served_changed(socket)

  defp served_change(%Change{old_struct: %SiteDevice{device_id: id}}, %{assigns: %{client: %{id: id}}} = socket),
    do: sites_served_changed(socket)

  defp served_change(%Change{op: :delete, old_struct: %Resource{} = resource}, socket) do
    if served?(socket, resource), do: push(socket, "local_resource_deleted", resource.id)
    socket
  end

  defp served_change(%Change{struct: %Resource{} = resource, old_struct: old_resource}, socket) do
    cond do
      served?(socket, resource) ->
        Enum.each(render_local_resource(resource), &push(socket, "local_resource_created_or_updated", &1))
        maybe_push_served_resource_change(socket, old_resource, resource)

      old_resource && served?(socket, old_resource) ->
        push(socket, "local_resource_deleted", resource.id)

      true ->
        :ok
    end

    socket
  end

  defp served_change(_change, socket), do: socket

  defp sites_served_changed(socket) do
    socket = assign(socket, :served_site_ids, Database.served_site_ids(socket.assigns.client))
    push(socket, "sites_served_changed", served_view(socket))
    send(self(), :track_presence)
    socket
  end

  defp served?(socket, %Resource{site_id: site_id}), do: site_id in socket.assigns.served_site_ids

  # The device keeps state only for peers authorized for the resource. A changed address or
  # type cannot be applied in place, so those peers are cut and authorize again; changed
  # filters are applied in place.
  defp maybe_push_served_resource_change(socket, %Resource{} = old, %Resource{type: type} = resource)
       when type != :device_pool do
    cond do
      old.address != resource.address or old.ip_stack != resource.ip_stack or old.type != type ->
        socket.assigns.authorizations_cache
        |> Cache.Authorizations.all_pairs_for_resource(resource.id)
        |> Enum.each(fn {client_id, resource_id} ->
          push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})
        end)

      old.filters != resource.filters ->
        [rendered] = render_local_resource(resource)
        push(socket, "resource_updated", rendered)

      true ->
        :ok
    end
  end

  defp maybe_push_served_resource_change(_socket, _old, _resource), do: :ok

  # A peer this device serves is told the candidates come from a gateway, so a legacy client
  # keeps its payloads. Every other peer is told they come from a client. A legacy client never
  # checks a client sender, so it is only sent candidates for an authorization this device holds.
  defp deliver_candidates(socket, peer_id, tag, candidates) do
    device_id = socket.assigns.client.id

    cond do
      Cache.Authorizations.has_client?(socket.assigns.authorizations_cache, peer_id) ->
        PG.deliver(peer_id, {tag, %{type: :gateway, id: device_id}, candidates})

      Cache.Authorizations.has_client?(socket.assigns.outbound_authorizations_cache, peer_id) or
          checks_client_senders?(socket.assigns.client.account_id, peer_id) ->
        PG.deliver(peer_id, {tag, %{type: :client, id: device_id}, candidates})

      true ->
        Telemetry.ice_candidates_dropped(:client, :unauthorized, length(candidates))
    end
  end

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
      type: :self,
      pool_id: Ecto.UUID.load!(resource.id),
      filters: Views.Resource.render_filters(resource.filters)
    }
  end

  defp target(%Cache.Cacheable.Resource{} = resource) do
    %{type: :resource, resource_id: Ecto.UUID.load!(resource.id)}
  end

  defp served_resource(%Cache.Cacheable.Resource{type: :device_pool}), do: nil
  defp served_resource(%Cache.Cacheable.Resource{} = resource), do: Views.Resource.render(resource)

  defp render_local_resource(%Portal.Resource{type: :device_pool}), do: []

  defp render_local_resource(%Portal.Resource{} = resource) do
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

    def served_site_ids(device) do
      from(sd in Portal.SiteDevice,
        where: sd.account_id == ^device.account_id and sd.device_id == ^device.id,
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
