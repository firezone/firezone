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

  describe "join/3" do
    test "tracks presence after join of an account relay", %{relay: relay} do
      presence = Domain.Relays.Presence.list("relays:#{relay.account_id}")

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, relay.id)
      assert is_number(online_at)
    end

    test "tracks presence after join of an global relay" do
      group = RelaysFixtures.create_global_group()
      relay = RelaysFixtures.create_relay(group: group)

      stamp_secret = Domain.Crypto.rand_string()

      {:ok, _, _socket} =
        API.Relay.Socket
        |> socket("relay:#{relay.id}", %{relay: relay})
        |> subscribe_and_join(API.Relay.Channel, "relay", %{stamp_secret: stamp_secret})

      presence = Domain.Relays.Presence.list("relays")

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, relay.id)
      assert is_number(online_at)
    end

    test "sends init message after join" do
      assert_push "init", %{}
    end
  end
end
