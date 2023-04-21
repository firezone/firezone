defmodule API.Client.Channel do
  use API, :channel
  alias Domain.Clients

  # TODO: we need to self-terminate channel once the user token is set to expire, preventing
  # users from holding infinite session for if they want to keep websocket open for a while

  @impl true
  def join("client", _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    :ok = Clients.connect_client(socket.assigns.client, socket)

    :ok =
      push(socket, "init", %{
        resources: [
          %{
            id: ...,
            dns_name: ...,
            ipv4:
            ipv6:
          }
        ],
        interface: %{
          upstream_dns: ["1.1.1.1", "8.8.8.8"],
          ipv4: client.ipv4,
          ipv6: client.ipv6
        }
      })

    {:noreply, socket}
  end

  def broadcast_resource_changes(resource, :added | :removed | :updated) do
    # add optimistic lock to resource.updated_at to serialize the resource updates
    {:ok, clients} = Resource.list_authorized_clients(resource)

    :ok =
      Enum.each(clients, fn client ->
        broadcast("clients:#{client.id}", "resource_changed", %{resource: nil})
      end)
  end

  def handle_in(
        "list_relays",
        %{
          "resource_id" => resource_id
        },
        socket
      ) do
    {:ok, resource} = Resources.fetch_by_id(resource_id)
    :ok = Resource.authorize(resource, socket.assigns.subject)
    {:ok, relays} = Relays.list_for_resource(resource)

    relays = [
      "stun:us-east-1.stun.firezone.dev:3478"
    ]

    reply("relays", %{relays: relays})
  end

  # TODO: later we want client to reuse connections for multiple resources that are
  # behind the same gateway
  def handle_in("request_connection", %{
        "resource_id" => resource_id,
        "client_rtc_session_description" => client_rtc_session_description,
        # TODO: preshared key should not be saved in the database, but rather generated
        # by client for every connection
        "client_preshared_key" => preshared_key
      }) do
    {:ok, resource} = Resources.fetch_by_id(resource_id)
    :ok = Resource.authorize(resource, socket.assigns.subject)
    {:ok, relays} = Relays.list_for_resource(resource)

    {:ok, gateways} = Gateways.list_live_for_resource(resource, relays)

    # Ask Tomas why we can't reuse rtc_session_description for multiple gateways
    gateway = Enum.random(gateways)

    {:ok, rtc_session_description} =
      Gateways.complete_rtc_session_description(gateway, client_rtc_session_description)

    {:reply,
     {"connect",
      %{
        "persistent_keepalive" => "",
        "gateway_public_key" => "",
        "gateway_rtc_session_description" => rtc_session_description
      }}, socket}
  end
end
