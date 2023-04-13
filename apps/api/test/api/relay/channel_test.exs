defmodule API.Relay.ChannelTest do
  use API.ChannelCase
  alias Domain.RelaysFixtures

  setup do
    relay = RelaysFixtures.create_relay()

    stamp_secret = Domain.Crypto.rand_string()

    {:ok, _, socket} =
      API.Relay.Socket
      |> socket("relay:#{relay.id}", %{relay: relay})
      |> subscribe_and_join(API.Relay.Channel, "relay", %{stamp_secret: stamp_secret})

    %{relay: relay, socket: socket}
  end

  test "tracks presence after join", %{relay: relay, socket: socket} do
    presence = Domain.Relays.Presence.list(socket)

    assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, relay.id)
    assert is_number(online_at)
  end
end
