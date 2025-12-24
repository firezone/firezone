defmodule API.Relay.ChannelTest do
  use API.ChannelCase, async: true

  import Domain.RelayFixtures
  import Domain.TokenFixtures

  setup do
    relay = relay_fixture()
    token = relay_token_fixture()

    stamp_secret = Domain.Crypto.random_token()

    {:ok, _, socket} =
      API.Relay.Socket
      |> socket("relay:#{relay.id}", %{
        token_id: token.id,
        relay: relay,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(API.Relay.Channel, "relay", %{stamp_secret: stamp_secret})

    %{relay: relay, socket: socket, token: token}
  end

  describe "join/3" do
    test "tracks presence after join", %{relay: relay} do
      presence = Domain.Presence.Relays.Global.list()

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, relay.id)
      assert is_number(online_at)
    end

    test "channel crash takes down the transport", %{socket: socket} do
      Process.flag(:trap_exit, true)

      # In tests, we (the test process) are the transport_pid
      assert socket.transport_pid == self()

      # Kill the channel - we receive EXIT because we're linked
      Process.exit(socket.channel_pid, :kill)

      assert_receive {:EXIT, pid, :killed}
      assert pid == socket.channel_pid
    end

    test "sends init message after join" do
      assert_push "init", %{}
    end
  end

  describe "handle_in/3 for unknown messages" do
    test "it doesn't crash", %{socket: socket} do
      ref = push(socket, "unknown_message", %{})

      assert_reply ref, :error, %{reason: :unknown_message}, 1000
    end
  end
end
