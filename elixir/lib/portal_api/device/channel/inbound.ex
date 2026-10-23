defmodule PortalAPI.Device.Channel.Inbound do
  @moduledoc """
  The receiving half of a device channel.

  An initiator's channel asks this device to accept a connection by sending
  an authorization to its channel. The channel pushes it to the device under
  the protocol's event, remembers it in `Portal.Cache.Inbound` under the
  `:inbound` assign, and tells the initiator once the device has it: on a
  protocol with a `:device_echo` ack the device answers with the signed ref
  it was handed, on an `:auto` one the channel answers as soon as the payload
  is on the socket, since the device's data plane reads the socket in order
  and any ICE candidate relayed afterwards cannot overtake it.

  Revocation runs the same path from every direction: a deleted row seen
  through replication, a queue that failed to persist, a durability timer
  that fired, or an operator's hand. The cached entry is dropped and, if it
  was still live, the device is told to reject the pair.
  """

  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 3]

  alias Portal.{Account, Cache, Resource, Telemetry}
  alias PortalAPI.Device.Channel.{Core, Durability}

  require Logger

  @prune_every :timer.minutes(1)

  @doc "Loads what the database says this device currently serves."
  @spec hydrate(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def hydrate(socket) do
    Process.send_after(self(), :prune_inbound, @prune_every)

    socket
    |> assign(:inbound, Cache.Inbound.hydrate(Core.device(socket)))
    |> assign(:iceless_capable, false)
  end

  @doc "Drops expired entries and reschedules itself."
  @spec prune(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def prune(socket) do
    Process.send_after(self(), :prune_inbound, @prune_every)
    assign(socket, :inbound, Cache.Inbound.prune(socket.assigns.inbound))
  end

  @doc "Whether the device currently serves `resource_id` to anyone."
  @spec serves_resource?(Phoenix.Socket.t(), Ecto.UUID.t()) :: boolean()
  def serves_resource?(socket, resource_id) do
    Cache.Inbound.has_resource?(socket.assigns.inbound, resource_id)
  end

  ####################################
  ##### Receiving authorizations #####
  ####################################

  @doc """
  An initiator asks this device to serve it a resource. The payload is the
  gateway-shaped authorization every initiator builds; the device is told
  under the protocol's event and the initiator hears back through
  `{:connect, ...}` once the device acknowledges.
  """
  @spec create_authorization(Phoenix.Socket.t(), {pid(), term()}, map()) ::
          {:noreply, Phoenix.Socket.t()}
  def create_authorization(socket, {channel_pid, socket_ref}, payload) do
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
    use_iceless = use_iceless?(socket, initiator_iceless_capable)

    record_authorization_granted(socket, initiator_iceless_capable)

    ref =
      encode_ref(socket, {
        channel_pid,
        socket_ref,
        rid_bytes,
        preshared_key,
        ice_credentials,
        use_iceless
      })

    authorization = %{
      ref: ref,
      resource: resource,
      gateway_ice_credentials: ice_credentials.receiver,
      client: client,
      client_ice_credentials: ice_credentials.initiator,
      expires_at: DateTime.to_unix(authorization_expires_at, :second),
      subject: subject,
      use_iceless: use_iceless,
      flow_logs_ingest_token: flow_logs_ingest_token
    }

    # The unified protocol names the device's ICE role, what it serves and
    # who asks, so the device can show the peer by name.
    authorization =
      if Core.protocol(socket).kind() == :device do
        Map.merge(authorization, %{
          ice_role: Map.get(payload, :ice_role, :controlled),
          target: %{type: :resource, resource_id: resource.id},
          client: Map.merge(client, %{name: payload[:client_name], slug: payload[:client_slug]})
        })
      else
        authorization
      end

    push(socket, Core.protocol(socket).create_authorization_event(), authorization)

    socket =
      socket
      |> put(policy_authorization_id, client.id, resource.id, authorization_expires_at)
      |> Durability.arm_authorization(payload[:policy_authorization])

    {:noreply, socket}
  end

  @doc """
  The device echoed the signed ref of an authorization it installed. The
  initiator is released with everything it needs to connect.
  """
  @spec authorization_created(Phoenix.Socket.t(), String.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def authorization_created(socket, signed_ref) do
    device = Core.device(socket)

    case decode_ref(socket, signed_ref) do
      {:ok, {:device_access, ack_to, ref, use_iceless}} ->
        send(ack_to, {:device_access_acked, ref, use_iceless, device.name, device.slug})

        {:reply, :ok, socket}

      {:ok, {channel_pid, socket_ref, resource_id, preshared_key, ice_credentials, use_iceless}} ->
        send(
          channel_pid,
          {
            :connect,
            socket_ref,
            resource_id,
            device.site_id,
            device.id,
            device.public_key,
            device.ipv4,
            device.ipv6,
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

  @doc """
  An initiating client asks this device, a client in one of its device
  pools, to accept a connection. On a protocol with an `:auto` ack the
  channel acknowledges on the device's behalf: the initiator must not start
  ICE before the authorization is on this socket, and once it is, nothing
  relayed later can pass it. With a `:device_echo` ack the payload carries a
  signed ref the device echoes once the authorization is installed.
  """
  @spec client_device_access_authorized(Phoenix.Socket.t(), {pid(), reference()}, map()) ::
          {:noreply, Phoenix.Socket.t()}
  def client_device_access_authorized(socket, {ack_to, ref}, payload) do
    device = Core.device(socket)

    {policy_authorization_id, payload} = Map.pop(payload, :policy_authorization_id)
    {authorization_expires_at, payload} = Map.pop(payload, :authorization_expires_at)
    {policy_authorization, payload} = Map.pop(payload, :policy_authorization)
    {initiator_iceless_capable, payload} = Map.pop(payload, :initiator_iceless_capable, false)

    use_iceless = use_iceless?(socket, initiator_iceless_capable)
    record_authorization_granted(socket, initiator_iceless_capable)

    payload = Map.put(payload, :use_iceless, use_iceless)

    socket =
      maybe_put(
        socket,
        payload[:client_id],
        payload[:resource],
        policy_authorization_id,
        authorization_expires_at
      )

    payload =
      if match?(%DateTime{}, authorization_expires_at) do
        Map.put(payload, :expires_at, DateTime.to_unix(authorization_expires_at, :second))
      else
        payload
      end

    # The resolved `use_iceless` travels with the ack so the initiator applies
    # the same decision without reading the flag a second time.
    case {Core.protocol(socket).kind(), Core.protocol(socket).ack_mode()} do
      {_kind, :auto} ->
        push(socket, "client_device_access_authorized", payload)
        send(ack_to, {:device_access_acked, ref, use_iceless, device.name, device.slug})

      {:device, :device_echo} ->
        # The unified protocol hears every authorization under one event,
        # this one with the device itself as the target through the pool.
        signed_ref = encode_ref(socket, {:device_access, ack_to, ref, use_iceless})

        push(socket, Core.protocol(socket).create_authorization_event(), %{
          ref: signed_ref,
          target: %{type: :self, pool_id: payload[:resource][:id], filters: payload[:resource][:filters]},
          client: %{
            id: payload[:client_id],
            name: payload[:client_name],
            slug: payload[:client_slug],
            public_key: payload[:client_public_key],
            ipv4: payload[:client_ipv4],
            ipv6: payload[:client_ipv6],
            preshared_key: payload[:preshared_key]
          },
          gateway_ice_credentials: payload[:local_ice_credentials],
          client_ice_credentials: payload[:remote_ice_credentials],
          ice_role: payload[:ice_role] || :controlled,
          subject: payload[:subject],
          expires_at: payload[:expires_at],
          use_iceless: use_iceless,
          flow_logs_ingest_token: payload[:flow_logs_ingest_token]
        })

      {_kind, :device_echo} ->
        signed_ref = encode_ref(socket, {:device_access, ack_to, ref, use_iceless})
        push(socket, "client_device_access_authorized", Map.put(payload, :ref, signed_ref))
    end

    {:noreply, Durability.arm_authorization(socket, policy_authorization)}
  end

  # DEPRECATED IN 1.4
  @doc false
  def allow_access(socket, {channel_pid, socket_ref}, attrs) do
    %{
      client_id: client_id,
      client_ipv4: client_ipv4,
      client_ipv6: client_ipv6,
      resource: %Cache.Cacheable.Resource{} = resource,
      policy_authorization_id: policy_authorization_id,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload
    } = attrs

    case Resource.adapt_resource_for_version(resource, Core.device(socket).last_seen_version) do
      nil ->
        {:noreply, socket}

      resource ->
        ref = encode_ref(socket, {channel_pid, socket_ref, resource.id})

        push(socket, "allow_access", %{
          ref: ref,
          client_id: client_id,
          resource: PortalAPI.Gateway.Views.Resource.render(resource),
          expires_at: DateTime.to_unix(authorization_expires_at, :second),
          payload: payload,
          client_ipv4: client_ipv4,
          client_ipv6: client_ipv6
        })

        record_authorization_granted(socket, false)

        socket =
          socket
          |> put(policy_authorization_id, client_id, resource.id, authorization_expires_at)
          |> Durability.arm_authorization(attrs[:policy_authorization])

        {:noreply, socket}
    end
  end

  # DEPRECATED IN 1.4
  @doc false
  def request_connection(socket, {channel_pid, socket_ref}, attrs) do
    %{
      client: client,
      resource: %Cache.Cacheable.Resource{} = resource,
      policy_authorization_id: policy_authorization_id,
      authorization_expires_at: authorization_expires_at
    } = attrs

    case Resource.adapt_resource_for_version(resource, Core.device(socket).last_seen_version) do
      nil ->
        {:noreply, socket}

      resource ->
        ref = encode_ref(socket, {channel_pid, socket_ref, resource.id})

        push(socket, "request_connection", %{
          ref: ref,
          resource: PortalAPI.Gateway.Views.Resource.render(resource),
          client: client,
          expires_at: DateTime.to_unix(authorization_expires_at, :second)
        })

        record_authorization_granted(socket, false)

        socket =
          socket
          |> put(policy_authorization_id, client.id, resource.id, authorization_expires_at)
          |> Durability.arm_authorization(attrs[:policy_authorization])

        {:noreply, socket}
    end
  end

  # DEPRECATED IN 1.4
  @doc false
  def connection_ready(socket, signed_ref, payload) do
    case decode_ref(socket, signed_ref) do
      {:ok, {channel_pid, socket_ref, rid_bytes}} ->
        send(
          channel_pid,
          {:connect, socket_ref, rid_bytes, Core.device(socket).public_key, payload}
        )

        {:reply, :ok, socket}

      {:error, :invalid_ref} ->
        Logger.error("Gateway replied with an invalid ref")
        {:reply, {:error, %{reason: :invalid_ref}}, socket}
    end
  end

  ####################################
  ##### Revoking authorizations ######
  ####################################

  @doc """
  Drops the cached authorization and, if it was still live, tells the device
  to reject the pair. The initiator recovers by tripping ICMP "destination
  prohibited" and asking for a fresh authorization. A row that had already
  expired (the reaper deleting it) is dropped silently: the device expired it
  on its own.
  """
  @spec revoke(Phoenix.Socket.t(), Portal.PolicyAuthorization.t()) :: {:noreply, Phoenix.Socket.t()}
  def revoke(socket, %Portal.PolicyAuthorization{
        id: id,
        initiating_device_id: initiating_device_id,
        resource_id: resource_id
      }) do
    case Cache.Inbound.delete(socket.assigns.inbound, id, initiating_device_id, resource_id) do
      {:ok, expires_at_unix, inbound} ->
        now_unix = DateTime.utc_now() |> DateTime.to_unix(:second)

        if expires_at_unix > now_unix do
          push(socket, "reject_access", %{client_id: initiating_device_id, resource_id: resource_id})
        end

        {:noreply, assign(socket, :inbound, inbound)}

      :error ->
        {:noreply, socket}
    end
  end

  @doc "A revocation that also stops the durability timer of the authorization."
  @spec reject_access(Phoenix.Socket.t(), Portal.PolicyAuthorization.t()) ::
          {:noreply, Phoenix.Socket.t()}
  def reject_access(socket, %Portal.PolicyAuthorization{} = pa) do
    socket
    |> Durability.confirm_authorization(pa.id)
    |> revoke(pa)
  end

  @doc """
  The self-heal escape hatch: rejects one `(initiator, resource)` pair and
  clears it locally, whatever the database says. See
  `PortalAPI.Device.Channel.Core.revoke_pair_access/3`.
  """
  @spec revoke_pair(Phoenix.Socket.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: {:noreply, Phoenix.Socket.t()}
  def revoke_pair(socket, client_id, resource_id) do
    push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})

    key = {Ecto.UUID.dump!(client_id), Ecto.UUID.dump!(resource_id)}

    # A pending durability timer for the pair would otherwise fire later,
    # find the cache empty, and log a spurious warning.
    socket =
      case Map.get(socket.assigns.inbound, key) do
        {pa_id_bytes, _exp} -> Durability.confirm_authorization(socket, Ecto.UUID.load!(pa_id_bytes))
        nil -> socket
      end

    {:noreply, assign(socket, :inbound, Map.delete(socket.assigns.inbound, key))}
  end

  @doc """
  A served resource changed in a way the device cannot follow (address, type
  or IP stack): every pair on it is rejected so the initiators re-authorize.
  The cache follows through the authorization deletions.
  """
  @spec reject_resource(Phoenix.Socket.t(), Ecto.UUID.t()) :: :ok
  def reject_resource(socket, resource_id) do
    for {client_id, resource_id} <-
          Cache.Inbound.all_pairs_for_resource(socket.assigns.inbound, resource_id) do
      push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})
    end

    :ok
  end

  @doc """
  A served resource's filters changed; the device is told the new shape when
  its version understands the resource. A device not serving the resource
  ignores the message.
  """
  @spec resource_updated(Phoenix.Socket.t(), Portal.Resource.t()) :: :ok
  def resource_updated(socket, %Portal.Resource{} = resource) do
    resource = Cache.Cacheable.to_cache(resource)

    case Resource.adapt_resource_for_version(resource, Core.device(socket).last_seen_version) do
      nil -> :ok
      adapted -> push(socket, "resource_updated", PortalAPI.Gateway.Views.Resource.render(adapted))
    end
  end

  ####################################
  ##### Helpers ######################
  ####################################

  defp put(socket, policy_authorization_id, initiating_device_id, resource_id, expires_at) do
    inbound =
      Cache.Inbound.put(
        socket.assigns.inbound,
        policy_authorization_id,
        initiating_device_id,
        resource_id,
        expires_at
      )

    assign(socket, :inbound, inbound)
  end

  defp maybe_put(socket, client_id, %{id: resource_id}, pa_id, %DateTime{} = expires_at)
       when is_binary(client_id) and is_binary(pa_id) do
    put(socket, pa_id, client_id, resource_id, expires_at)
  end

  defp maybe_put(socket, _client_id, _resource, _pa_id, _expires_at), do: socket

  defp use_iceless?(socket, initiator_iceless_capable) do
    socket.assigns.iceless_capable == true and initiator_iceless_capable == true and
      Account.iceless_enabled?(Core.account(socket))
  end

  defp record_authorization_granted(socket, initiator_iceless_capable) do
    Telemetry.authorization_granted(telemetry_receiver(socket),
      iceless_feature_enabled: Account.iceless_enabled?(Core.account(socket)),
      initiator_iceless_capable: initiator_iceless_capable == true,
      receiver_iceless_capable: socket.assigns.iceless_capable == true
    )
  end

  defp telemetry_receiver(socket) do
    case Core.protocol(socket).kind() do
      :client -> :client
      _ -> :gateway
    end
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
end
