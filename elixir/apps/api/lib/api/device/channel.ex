defmodule API.Device.Channel do
  use API, :channel
  alias API.Device.Views
  alias Domain.{Devices, Resources, Gateways, Relays}
  require Logger

  @impl true
  def join("device", _payload, socket) do
    expires_in =
      DateTime.diff(socket.assigns.subject.expires_at, DateTime.utc_now(), :millisecond)

    if expires_in > 0 do
      Process.send_after(self(), :token_expired, expires_in)
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, %{"reason" => "token_expired"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    API.Endpoint.subscribe("device:#{socket.assigns.device.id}")
    :ok = Devices.connect_device(socket.assigns.device)

    {:ok, resources} = Domain.Resources.list_resources(socket.assigns.subject)

    :ok =
      push(socket, "init", %{
        resources: Views.Resource.render_many(resources),
        interface: Views.Interface.render(socket.assigns.device)
      })

    {:noreply, socket}
  end

  def handle_info(:token_expired, socket) do
    push(socket, "token_expired", %{})
    {:stop, :token_expired, socket}
  end

  # This message is sent by the gateway when it is ready
  # to accept the connection from the device
  def handle_info(
        {:connect, socket_ref, resource_id, gateway_public_key, rtc_session_description},
        socket
      ) do
    reply(
      socket_ref,
      {:ok,
       %{
         resource_id: resource_id,
         persistent_keepalive: 25,
         gateway_public_key: gateway_public_key,
         gateway_rtc_session_description: rtc_session_description
       }}
    )

    {:noreply, socket}
  end

  def handle_info({:resource_added, resource_id}, socket) do
    with {:ok, resource} <- Resources.fetch_resource_by_id(resource_id, socket.assigns.subject) do
      push(socket, "resource_added", Views.Resource.render(resource))
    end

    {:noreply, socket}
  end

  def handle_info({:resource_updated, resource_id}, socket) do
    with {:ok, resource} <- Resources.fetch_resource_by_id(resource_id, socket.assigns.subject) do
      push(socket, "resource_updated", Views.Resource.render(resource))
    end

    {:noreply, socket}
  end

  def handle_info({:resource_removed, resource_id}, socket) do
    push(socket, "resource_removed", resource_id)
    {:noreply, socket}
  end

  @impl true
  def handle_in("prepare_connection", %{"resource_id" => resource_id} = attrs, socket) do
    connected_gateway_ids = Map.get(attrs, "connected_gateway_ids", [])

    with {:ok, resource} <- Resources.fetch_resource_by_id(resource_id, socket.assigns.subject),
         # :ok = Resource.authorize(resource, socket.assigns.subject),
         {:ok, [_ | _] = gateways} <-
           Gateways.list_connected_gateways_for_resource(resource),
         {:ok, [_ | _] = relays} <- Relays.list_connected_relays_for_resource(resource) do
      gateway = Gateways.load_balance_gateways(gateways, connected_gateway_ids)

      reply =
        {:ok,
         %{
           relays: Views.Relay.render_many(relays, socket.assigns.subject.expires_at),
           resource_id: resource_id,
           gateway_id: gateway.id,
           gateway_remote_ip: gateway.last_seen_remote_ip
         }}

      {:reply, reply, socket}
    else
      {:ok, []} -> {:reply, {:error, :offline}, socket}
      {:error, :not_found} -> {:reply, {:error, :not_found}, socket}
    end
  end

  # This message is sent by the device when it already has connection to a gateway,
  # but wants to connect to a new resource
  def handle_in(
        "reuse_connection",
        %{
          "gateway_id" => gateway_id,
          "resource_id" => resource_id
        },
        socket
      ) do
    with {:ok, resource} <- Resources.fetch_resource_by_id(resource_id, socket.assigns.subject),
         #  :ok = Resource.authorize(resource, socket.assigns.subject),
         {:ok, gateway} <- Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject),
         true <- Gateways.gateway_can_connect_to_resource?(gateway, resource) do
      :ok =
        API.Gateway.Channel.broadcast(
          gateway,
          {:allow_access,
           %{
             device_id: socket.assigns.device.id,
             resource_id: resource.id,
             authorization_expires_at: socket.assigns.subject.expires_at
           }}
        )

      {:noreply, socket}
    else
      {:error, :not_found} -> {:reply, {:error, :not_found}, socket}
      false -> {:reply, {:error, :offline}, socket}
    end
  end

  # This message is sent by the device when it wants to connect to a new gateway
  def handle_in(
        "request_connection",
        %{
          "gateway_id" => gateway_id,
          "resource_id" => resource_id,
          "device_rtc_session_description" => device_rtc_session_description,
          "device_preshared_key" => preshared_key
        },
        socket
      ) do
    with {:ok, resource} <- Resources.fetch_resource_by_id(resource_id, socket.assigns.subject),
         #  :ok = Resource.authorize(resource, socket.assigns.subject),
         {:ok, gateway} <- Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject),
         true <- Gateways.gateway_can_connect_to_resource?(gateway, resource) do
      :ok =
        API.Gateway.Channel.broadcast(
          gateway,
          {:request_connection, {self(), socket_ref(socket)},
           %{
             device_id: socket.assigns.device.id,
             resource_id: resource.id,
             authorization_expires_at: socket.assigns.subject.expires_at,
             device_rtc_session_description: device_rtc_session_description,
             device_preshared_key: preshared_key
           }}
        )

      {:noreply, socket}
    else
      {:error, :not_found} -> {:reply, {:error, :not_found}, socket}
      false -> {:reply, {:error, :offline}, socket}
    end
  end
end
