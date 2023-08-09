defmodule API.Relay.Socket do
  use Phoenix.Socket
  alias Domain.Relays
  require Logger

  ## Channels

  channel "relay", API.Relay.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => encrypted_secret} = attrs, socket, connect_info) do
    %{
      user_agent: user_agent,
      x_headers: x_headers,
      peer_data: peer_data
    } = connect_info

    real_ip = API.Sockets.real_ip(x_headers, peer_data)

    attrs =
      attrs
      |> Map.take(~w[ipv4 ipv6])
      |> Map.put("last_seen_user_agent", user_agent)
      |> Map.put("last_seen_remote_ip", real_ip)

    with {:ok, token} <- Relays.authorize_relay(encrypted_secret),
         {:ok, relay} <- Relays.upsert_relay(token, attrs) do
      socket =
        socket
        |> assign(:relay, relay)

      {:ok, socket}
    else
      {:error, reason} ->
        Logger.debug("Error connecting relay websocket: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true
  def id(%Relays.Relay{} = relay), do: "relay:#{relay.id}"
  def id(socket), do: id(socket.assigns.relay)
end
