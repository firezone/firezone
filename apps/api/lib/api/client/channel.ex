defmodule API.Client.Channel do
  use API, :channel
  alias API.Client.Views
  alias Domain.{Clients, Resources, Gateways, Relays}

  @impl true
  def join("client", _payload, socket) do
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
    {:ok, resources} = Domain.Resources.list_resources(socket.assigns.subject)

    :ok =
      push(socket, "init", %{
        resources: Views.Resource.render_many(resources),
        interface: Views.Interface.render(socket.assigns.client)
      })

    :ok = Clients.connect_client(socket.assigns.client)

    {:noreply, socket}
  end

  def handle_info(:token_expired, socket) do
    push(socket, "token_expired", %{})
    {:stop, :token_expired, socket}
  end

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
  def handle_in("list_relays", %{"resource_id" => resource_id}, socket) do
    with {:ok, resource} <- Resources.fetch_resource_by_id(resource_id, socket.assigns.subject),
         # :ok = Resource.authorize(resource, socket.assigns.subject),
         {:ok, [_ | _] = relays} <- Relays.list_connected_relays_for_resource(resource) do
      reply = {:ok, %{relays: Views.Relay.render_many(relays, socket.assigns.expires_at)}}
      {:reply, reply, socket}
    else
      {:ok, []} -> {:reply, {:error, :offline}, socket}
      {:error, :not_found} -> {:reply, {:error, :not_found}, socket}
    end
  end

  def handle_in(
        "request_connection",
        %{
          "resource_id" => resource_id,
          "client_rtc_session_description" => client_rtc_session_description,
          "client_preshared_key" => preshared_key
        },
        socket
      ) do
    with {:ok, resource} <- Resources.fetch_resource_by_id(resource_id, socket.assigns.subject),
         #  :ok = Resource.authorize(resource, socket.assigns.subject),
         {:ok, [_ | _] = gateways} <-
           Gateways.list_connected_gateways_for_resource(resource) do
      gateway = Enum.random(gateways)

      Phoenix.PubSub.broadcast(
        Domain.PubSub,
        API.Gateway.Socket.id(gateway),
        {:request_connection, {self(), socket_ref(socket)},
         %{
           client_id: socket.assigns.client.id,
           resource_id: resource_id,
           authorization_expires_at: socket.assigns.expires_at,
           client_rtc_session_description: client_rtc_session_description,
           client_preshared_key: preshared_key
         }}
      )

      {:noreply, socket}
    else
      {:error, :not_found} -> {:reply, {:error, :not_found}, socket}
      {:ok, []} -> {:reply, {:error, :offline}, socket}
    end
  end
end
