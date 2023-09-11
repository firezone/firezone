defmodule API.Gateway.Channel do
  use API, :channel
  alias API.Gateway.Views
  alias Domain.{Clients, Resources, Relays, Gateways}
  require Logger

  def broadcast(%Gateways.Gateway{} = gateway, payload) do
    Logger.debug("Gateway message is being dispatched", gateway_id: gateway.id)
    Phoenix.PubSub.broadcast(Domain.PubSub, "gateway:#{gateway.id}", payload)
  end

  @impl true
  def join("gateway", _payload, socket) do
    send(self(), :after_join)
    socket = assign(socket, :refs, %{})
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    :ok = Gateways.connect_gateway(socket.assigns.gateway)
    :ok = API.Endpoint.subscribe("gateway:#{socket.assigns.gateway.id}")

    push(socket, "init", %{
      interface: Views.Interface.render(socket.assigns.gateway),
      # TODO: move to settings
      ipv4_masquerade_enabled: true,
      ipv6_masquerade_enabled: true
    })

    {:noreply, socket}
  end

  def handle_info({:allow_access, attrs}, socket) do
    %{
      client_id: client_id,
      resource_id: resource_id,
      authorization_expires_at: authorization_expires_at
    } = attrs

    resource = Resources.fetch_resource_by_id!(resource_id)

    push(socket, "allow_access", %{
      client_id: client_id,
      resource: Views.Resource.render(resource),
      expires_at: DateTime.to_unix(authorization_expires_at, :second)
    })

    {:noreply, socket}
  end

  def handle_info({:request_connection, {channel_pid, socket_ref}, attrs}, socket) do
    %{
      client_id: client_id,
      resource_id: resource_id,
      authorization_expires_at: authorization_expires_at,
      client_rtc_session_description: rtc_session_description,
      client_preshared_key: preshared_key
    } = attrs

    Logger.debug("Gateway received connection request message",
      client_id: client_id,
      resource_id: resource_id
    )

    client = Clients.fetch_client_by_id!(client_id, preload: [:actor])
    resource = Resources.fetch_resource_by_id!(resource_id)
    {:ok, relays} = Relays.list_connected_relays_for_resource(resource)

    ref = Ecto.UUID.generate()

    push(socket, "request_connection", %{
      ref: ref,
      actor: Views.Actor.render(client.actor),
      relays: Views.Relay.render_many(relays, authorization_expires_at),
      resource: Views.Resource.render(resource),
      client: Views.Client.render(client, rtc_session_description, preshared_key),
      expires_at: DateTime.to_unix(authorization_expires_at, :second)
    })

    Logger.debug("Awaiting gateway connection_ready message",
      client_id: client_id,
      resource_id: resource_id,
      ref: ref
    )

    refs = Map.put(socket.assigns.refs, ref, {channel_pid, socket_ref, resource_id})
    socket = assign(socket, :refs, refs)

    {:noreply, socket}
  end

  @impl true
  def handle_in(
        "connection_ready",
        %{
          "ref" => ref,
          "gateway_rtc_session_description" => rtc_session_description
        },
        socket
      ) do
    {{channel_pid, socket_ref, resource_id}, refs} = Map.pop(socket.assigns.refs, ref)
    socket = assign(socket, :refs, refs)

    send(
      channel_pid,
      {:connect, socket_ref, resource_id, socket.assigns.gateway.public_key,
       rtc_session_description}
    )

    Logger.debug("Gateway replied to the Client with :connect message",
      resource_id: resource_id,
      channel_pid: inspect(channel_pid),
      ref: ref
    )

    {:reply, :ok, socket}
  end

  # def handle_in("metrics", params, socket) do
  #   %{
  #     "started_at" => started_at,
  #     "ended_at" => ended_at,
  #     "metrics" => [
  #       %{
  #         "client_id" => client_id,
  #         "resource_id" => resource_id,
  #         "rx_bytes" => 0,
  #         "tx_packets" => 0
  #       }
  #     ]
  #   }

  #   :ok = Gateways.update_metrics(socket.assigns.relay, metrics)
  #   {:noreply, socket}
  # end
end
