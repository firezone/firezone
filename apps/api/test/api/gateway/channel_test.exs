defmodule API.Gateway.ChannelTest do
  use API.ChannelCase
  alias Domain.GatewaysFixtures

  setup do
    gateway = GatewaysFixtures.create_gateway()

    {:ok, _, socket} =
      API.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{gateway: gateway})
      |> subscribe_and_join(API.Gateway.Channel, "gateway")

    %{gateway: gateway, socket: socket}
  end

  test "tracks presence after join", %{gateway: gateway, socket: socket} do
    presence = Domain.Gateways.Presence.list(socket)

    assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, gateway.id)
    assert is_number(online_at)
  end
end
