defmodule API.Gateway.Channel do
  use API, :channel
  alias Domain.Gateways

  @impl true
  def join("gateway", _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    Gateways.connect_gateway(socket.assigns.gateway, socket)

    push(socket, "init", %{
      resources: [

      ],
      interface: %{
        ipv4: gateway.ipv4,
        ipv6: gateway.ipv6
      },
      ipv4_masquerade_enabled: true,
      ipv6_masquerade_enabled: true
    })

    {:noreply, socket}
  end

  def complete_rtc_session_description(gateway, client_rtc_session_description, relays) do
    relays = [
      "stun:us-east-1.stun.firezone.dev:3478"
    ]

    broadcast("gateways:#{gateway.id}", "request_connection", %{
      "user_id" => "user_id",
      "relays" => relays,
      "resource" => %{
        "id" => resource_id,
        "destination" => [
          "DNS_NAME" | [public_ipv4, public_ipv6]
        ]
        # resource IP can be public?
        "internal_ipv4" => resource.ipv4,
        "internal_ipv6" => resource.ipv6
      },
      "client" => %{
        "id" => ...,
        "rtc_session_description" => client_rtc_session_description,
        "peer" => %{
          "persistent_keepalive" => ...,
          "public_key" => ...,
          "preshared_key" => ...,
          "ipv4" => client.ipv4,
          "ipv6" => client.ipv6
        }
      },
      "expires_at" => "when_the_client_token_expires"
    })
  end

  def handle_in(
        "connection_ready",
        %{
          # TODO: maybe add message_ref instead of looking it up by client_id
          "client_id" => client_id,
          "gateway_rtc_session_description" => rtc_session_description
        },
        socket
      ) do
    :ok = Clients.forward_rtc_session_description(client, rtc_session_description)
    {:noreply, socket}
  end

  def handle_in("metrics", metrics, socket) do
    metrics = %{
      "client_id" => client_id,
      "resource_id" => resource_id,
      "rx_bytes" => 0,
      "tx_packets" => 0,

    }
    :ok = Gateways.update_metrics(socket.assigns.gateway, metrics)
    {:noreply, socket}
  end
end
