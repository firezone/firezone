defmodule PortalAPI.Relay.ChannelTest do
  use PortalAPI.ChannelCase, async: true
  import ExUnit.CaptureLog

  import Portal.RelayFixtures
  import Portal.TokenFixtures

  setup do
    relay = relay_fixture()
    token = relay_token_fixture()

    stamp_secret = Portal.Crypto.random_token()

    {:ok, _, socket} =
      PortalAPI.Relay.Socket
      |> socket("relay:#{relay.id}", %{
        token_id: token.id,
        relay: relay,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Relay.Channel, "relay", %{stamp_secret: stamp_secret})

    %{relay: relay, socket: socket, token: token}
  end

  describe "join/3" do
    test "tracks presence after join", %{relay: relay} do
      presence = Portal.Presence.Relays.Global.list()

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, relay.id)
      assert is_number(online_at)
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

    test "kills existing connection when new relay connects with same stamp_secret" do
      # Create a new relay
      relay = relay_fixture()
      token = relay_token_fixture()
      stamp_secret = Portal.Crypto.random_token()

      test_pid = self()

      # Capture the test-specific topic before spawning
      topic = Portal.Presence.Relays.Global.topic()

      # First "connection" - spawn a process that tracks presence directly
      first_pid =
        spawn(fn ->
          # Track presence directly using the test-specific topic
          {:ok, _} =
            Portal.Presence.track(self(), topic, relay.id, %{
              online_at: System.system_time(:second),
              secret: stamp_secret,
              token_id: token.id,
              ipv4: relay.ipv4,
              ipv6: relay.ipv6,
              port: relay.port,
              last_seen_remote_ip_location_lat: relay.last_seen_remote_ip_location_lat,
              last_seen_remote_ip_location_lon: relay.last_seen_remote_ip_location_lon
            })

          send(test_pid, :first_connected)

          # Keep the process alive until killed
          Process.sleep(:infinity)
        end)

      # Wait for first connection to be tracked
      assert_receive :first_connected, 1000

      # Verify first connection is tracked
      presence = Portal.Presence.Relays.Global.list()
      assert %{metas: [%{secret: ^stamp_secret}]} = Map.fetch!(presence, relay.id)

      # Monitor the first process
      ref = Process.monitor(first_pid)

      # Second connection with same stamp_secret (this should kill the first)
      :ok = Portal.Presence.Relays.connect(relay, stamp_secret, token.id)

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

  describe "handle_info/2 :check_idle_timeout" do
    alias __MODULE__.MockTransport

    test "logs warning when timeout_num reaches threshold", %{relay: relay} do
      # Start a GenServer that mimics the cowboy transport state
      {:ok, transport_pid} = MockTransport.start_link(timeout_num: 9)

      socket = %Phoenix.Socket{
        assigns: %{relay: relay},
        transport_pid: transport_pid
      }

      log =
        capture_log(fn ->
          {:noreply, _socket} =
            PortalAPI.Relay.Channel.handle_info(:check_idle_timeout, socket)
        end)

      assert log =~ "[warning]"
      assert log =~ "Relay missed heartbeat"
      assert log =~ relay.id
      assert log =~ "timeout_ticks=9"
    end

    test "does not log when timeout_num is below threshold", %{relay: relay} do
      {:ok, transport_pid} = MockTransport.start_link(timeout_num: 5)

      socket = %Phoenix.Socket{
        assigns: %{relay: relay},
        transport_pid: transport_pid
      }

      log =
        capture_log(fn ->
          {:noreply, _socket} =
            PortalAPI.Relay.Channel.handle_info(:check_idle_timeout, socket)
        end)

      refute log =~ "Relay missed heartbeat"
    end

    test "does not log when transport state cannot be read", %{relay: relay} do
      # Use a dead process
      pid = spawn(fn -> :ok end)
      Process.sleep(10)

      socket = %Phoenix.Socket{
        assigns: %{relay: relay},
        transport_pid: pid
      }

      log =
        capture_log(fn ->
          {:noreply, _socket} =
            PortalAPI.Relay.Channel.handle_info(:check_idle_timeout, socket)
        end)

      refute log =~ "Relay missed heartbeat"
    end
  end

  # GenServer that mimics cowboy websocket state for :sys.get_state/2
  defmodule MockTransport do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      timeout_num = Keyword.fetch!(opts, :timeout_num)

      # Cowboy websocket state: {{:state, ...}, handler_state, parse_state}
      state =
        {{:state, nil, nil, nil, nil, %{}, nil, nil, nil, nil, timeout_num, nil, nil, nil, nil,
          nil, nil, nil, nil, nil, nil, nil}, nil, nil}

      {:ok, state}
    end
  end
end
