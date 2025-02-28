defmodule API.Relay.ChannelTest do
  use API.ChannelCase, async: true
  alias Domain.Relays

  setup do
    relay = Fixtures.Relays.create_relay()

    stamp_secret = Domain.Crypto.random_token()

    {:ok, _, socket} =
      API.Relay.Socket
      |> socket("relay:#{relay.id}", %{
        relay: relay,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(API.Relay.Channel, "relay", %{stamp_secret: stamp_secret})

    %{relay: relay, socket: socket}
  end

  describe "join/3" do
    test "tracks presence after join of an account relay", %{relay: relay} do
      presence = Relays.Presence.list(Relays.account_presence_topic(relay.account_id))

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, relay.id)
      assert is_number(online_at)
    end

    test "tracks presence after join of an global relay" do
      group = Fixtures.Relays.create_global_group()
      relay = Fixtures.Relays.create_relay(group: group)

      stamp_secret = Domain.Crypto.random_token()

      {:ok, _, _socket} =
        API.Relay.Socket
        |> socket("relay:#{relay.id}", %{
          relay: relay,
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
        })
        |> subscribe_and_join(API.Relay.Channel, "relay", %{stamp_secret: stamp_secret})

      presence = Relays.Presence.list(Relays.global_groups_presence_topic())

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, relay.id)
      assert is_number(online_at)
    end

    test "sends init message after join" do
      assert_push "init", %{}
    end
  end

  describe "handle_in/3 for unknown messages" do
    test "it doesn't crash", %{socket: socket} do
      ref = push(socket, "unknown_message", %{})
      assert_reply ref, :error, %{reason: :unknown_message}
    end
  end
end
