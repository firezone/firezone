defmodule PortalAPI.Relay.ChannelTest do
  use PortalAPI.ChannelCase, async: true

  import Portal.RelayFixtures
  import Portal.TokenFixtures

  setup do
    relay = relay_fixture()
    token = relay_token_fixture()

    stamp_secret = relay.stamp_secret

    {:ok, _, socket} =
      PortalAPI.Relay.Socket
      |> socket("relay:#{stamp_secret}", %{
        token_id: token.id,
        relay: relay,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Relay.Channel, "relay", %{stamp_secret: stamp_secret})

    %{relay: relay, socket: socket, token: token, stamp_secret: stamp_secret}
  end

  describe "join/3" do
    test "tracks presence after join", %{relay: relay} do
      presence = Portal.Presence.Relays.Global.list()

      assert %{metas: [%{ipv4: _, phx_ref: _ref}]} = Map.fetch!(presence, relay.id)
    end

    test "channel crash takes down the transport", %{socket: socket} do
      Process.flag(:trap_exit, true)

      # In tests, we (the test process) are the transport_pid
      assert socket.transport_pid == self()

      # Kill the channel - we receive EXIT because we're linked
      Process.exit(socket.channel_pid, :shutdown)

      assert_receive {:EXIT, pid, :shutdown}
      assert pid == socket.channel_pid
    end

    test "sends init message after join" do
      assert_push "init", %{}
    end

    test "kills existing connection when new relay connects with same id" do
      # Create a new relay with a known stamp_secret
      relay = relay_fixture()

      test_pid = self()

      # Capture the test-specific topic before spawning
      topic = Portal.Presence.Relays.Global.topic()

      # First "connection" - spawn a process that tracks presence directly
      first_pid =
        spawn(fn ->
          # Track presence directly using the relay ID
          {:ok, _} =
            Portal.Presence.track(self(), topic, relay.id, %{
              stamp_secret: relay.stamp_secret,
              ipv4: relay.ipv4,
              ipv6: relay.ipv6,
              port: relay.port,
              lat: relay.lat,
              lon: relay.lon
            })

          send(test_pid, :first_connected)

          # Keep the process alive until killed
          Process.sleep(:infinity)
        end)

      # Wait for first connection to be tracked
      assert_receive :first_connected, 1000

      # Verify first connection is tracked
      presence = Portal.Presence.Relays.Global.list()
      assert %{metas: [%{ipv4: _}]} = Map.fetch!(presence, relay.id)

      # Monitor the first process
      ref = Process.monitor(first_pid)

      # Second connection with same ID (this should kill the first)
      :ok = Portal.Presence.Relays.connect(relay)

      # First process should be killed
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :shutdown}, 1000
    end
  end

  describe "handle_in/3 for unknown messages" do
    test "it doesn't crash", %{socket: socket} do
      ref = push(socket, "unknown_message", %{})

      assert_reply ref, :error, %{reason: :unknown_message}, 1000
    end
  end
end
