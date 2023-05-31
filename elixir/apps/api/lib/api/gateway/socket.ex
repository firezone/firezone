defmodule API.Gateway.Socket do
  use Phoenix.Socket
  alias Domain.Gateways

  ## Channels

  channel "gateway:*", API.Gateway.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => encrypted_secret} = attrs, socket, connect_info) do
    %{user_agent: user_agent, peer_data: %{address: remote_ip}} = connect_info

    attrs =
      attrs
      |> Map.take(~w[external_id name_suffix public_key])
      |> Map.put("last_seen_user_agent", user_agent)
      |> Map.put("last_seen_remote_ip", remote_ip)

    with {:ok, token} <- Gateways.authorize_gateway(encrypted_secret),
         {:ok, gateway} <- Gateways.upsert_gateway(token, attrs) do
      socket =
        socket
        |> assign(:gateway, gateway)

      {:ok, socket}
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true
  def id(%Gateways.Gateway{} = gateway), do: "gateway:#{gateway.id}"
  def id(socket), do: id(socket.assigns.gateway)
end
