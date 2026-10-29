defmodule PortalAPI.Relay.ChannelTest do
  use PortalAPI.ChannelCase, async: true

  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.Changes.Hooks.Accounts
  import Portal.RelayFixtures
  import Portal.TokenFixtures

  setup do
    Portal.Config.put_env_override(
      :portal,
      :account_changes_topic,
      "accounts:#{inspect(make_ref())}"
    )

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
      presence = Portal.Presence.Relays.list()

      assert %{metas: [%{ipv4: _, phx_ref: _ref}]} = Map.fetch!(presence, relay.id)
    end

    test "an abnormal channel exit drains the transport so connlib reconnects", %{socket: socket} do
      Process.flag(:trap_exit, true)

      # In ChannelTest the test process is the transport_pid, so terminate/2's
      # drain lands in our mailbox.
      assert socket.transport_pid == self()

      # An abnormal stop runs terminate/2, modeling an in-process crash (e.g. a
      # Postgrex query raising on timeout). The harness links us, hence {:EXIT}.
      capture_log(fn ->
        GenServer.stop(socket.channel_pid, :boom)
        assert_receive {:EXIT, _pid, :boom}
      end)

      assert_receive :socket_drain
    end

    test "a graceful channel stop does NOT drain the transport", %{socket: socket} do
      Process.flag(:trap_exit, true)
      assert socket.transport_pid == self()

      # A :shutdown stop already sends phx_close, which connlib treats as a clean
      # reconnect, so terminate/2 must NOT additionally drain the transport.
      GenServer.stop(socket.channel_pid, :shutdown)

      refute_receive :socket_drain
    end

    test "sends init message after join" do
      assert_push "init", %{}
    end

    test "includes account IDs in init only for Relays that support account validation" do
      assert_push "init", %{}
      account = account_fixture()
      relay = relay_fixture()
      token = relay_token_fixture()

      {:ok, _, _socket} =
        PortalAPI.Relay.Socket
        |> socket("relay:#{relay.stamp_secret}", %{
          token_id: token.id,
          relay: relay,
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
        })
        |> subscribe_and_join(PortalAPI.Relay.Channel, "relay", %{
          stamp_secret: relay.stamp_secret,
          turn_account_validation: true
      })

      assert_push "init", %{account_ids: account_ids}
      assert account.id in account_ids
    end

    test "includes throughput limits of limited accounts in init" do
      assert_push "init", %{}
      limited = account_fixture(limits: %{relay_throughput_mbps: 25})
      unlimited = account_fixture(limits: %{relay_throughput_mbps: 0})
      join_capable_relay()

      assert_push "init", %{throughput_limits_bps: throughput_limits_bps}
      assert throughput_limits_bps[limited.id] == 25_000_000
      refute Map.has_key?(throughput_limits_bps, unlimited.id)
    end

    test "forwards throughput limit changes to capable Relays" do
      assert_push "init", %{}
      join_capable_relay()
      assert_push "init", %{account_ids: _account_ids}
      account_id = "00000000-0000-0000-0000-000000000005"

      :ok =
        on_update(
          1,
          %{"id" => account_id, "is_disabled" => false, "limits" => %{}},
          %{"id" => account_id, "is_disabled" => false, "limits" => %{"relay_throughput_mbps" => 10}}
        )

      assert_push "account_added", %{account_id: ^account_id, throughput_limit_bps: 10_000_000}

      :ok =
        on_update(
          2,
          %{"id" => account_id, "is_disabled" => false, "limits" => %{"relay_throughput_mbps" => 10}},
          %{"id" => account_id, "is_disabled" => false, "limits" => %{"relay_throughput_mbps" => 0}}
        )

      assert_push "account_added", %{account_id: ^account_id, throughput_limit_bps: nil}
    end

    test "includes derived allocation limits of limited accounts in init" do
      assert_push "init", %{}
      limited = account_fixture(limits: %{users_count: 100, monthly_active_users_count: nil, connected_devices_per_actor: 5})
      unlimited = account_fixture(limits: %{connected_devices_per_actor: nil})
      join_capable_relay()

      assert_push "init", %{allocation_limits: allocation_limits}
      assert allocation_limits[limited.id] == 520
      refute Map.has_key?(allocation_limits, unlimited.id)
    end

    test "forwards recalculated quotas on seat increases, decreases, and unlimited changes" do
      assert_push "init", %{}
      join_capable_relay()
      assert_push "init", %{account_ids: _account_ids}
      account_id = "00000000-0000-0000-0000-000000000005"
      initial = %{"users_count" => 1000, "monthly_active_users_count" => 100, "connected_devices_per_actor" => 10}
      increased = %{initial | "monthly_active_users_count" => 200}
      unlimited = %{initial | "connected_devices_per_actor" => nil}

      for {lsn, old_limits, new_limits, expected} <- [
            {1, initial, increased, 2030},
            {2, increased, initial, 1020},
            {3, initial, unlimited, nil},
            {4, unlimited, initial, 1020}
          ] do
        assert :ok == on_update(lsn,
          %{"id" => account_id, "is_disabled" => false, "limits" => old_limits},
          %{"id" => account_id, "is_disabled" => false, "limits" => new_limits})

        assert_push "account_added", %{account_id: ^account_id, allocation_limit: ^expected}
      end
    end

    test "forwards account lifecycle changes to capable Relays" do
      assert_push "init", %{}
      relay = relay_fixture()
      token = relay_token_fixture()

      {:ok, _, _socket} =
        PortalAPI.Relay.Socket
        |> socket("relay:#{relay.stamp_secret}", %{
          token_id: token.id,
          relay: relay,
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
        })
        |> subscribe_and_join(PortalAPI.Relay.Channel, "relay", %{
          stamp_secret: relay.stamp_secret,
          turn_account_validation: true
        })

      assert_push "init", %{account_ids: _account_ids}

      account_id = "00000000-0000-0000-0000-000000000004"
      :ok = on_insert(1, %{"id" => account_id, "is_disabled" => false})

      assert_push "account_added", %{account_id: ^account_id}

      :ok = on_delete(2, %{"id" => account_id})

      assert_push "account_removed", %{account_id: ^account_id}
    end

    test "kills existing connection when new relay connects with same id" do
      # Create a new relay with a known stamp_secret
      relay = relay_fixture()

      test_pid = self()

      # Capture the test-specific topic before spawning
      topic = Portal.Presence.Relays.topic()

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
      presence = Portal.Presence.Relays.list()
      assert %{metas: [%{ipv4: _}]} = Map.fetch!(presence, relay.id)

      # Monitor the first process
      ref = Process.monitor(first_pid)

      # Second connection with same ID (this should kill the first)
      :ok = Portal.Presence.Relays.connect(relay)

      # First process should be killed
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :shutdown}, 1000
    end
  end

  defp join_capable_relay do
    relay = relay_fixture()
    token = relay_token_fixture()

    {:ok, _, socket} =
      PortalAPI.Relay.Socket
      |> socket("relay:#{relay.stamp_secret}", %{
        token_id: token.id,
        relay: relay,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Relay.Channel, "relay", %{
        stamp_secret: relay.stamp_secret,
        turn_account_validation: true
      })

    socket
  end

  describe "handle_in/3 for unknown messages" do
    test "it doesn't crash", %{socket: socket} do
      assert_push "init", %{}
      ref = push(socket, "unknown_message", %{})

      assert_reply ref, :error, %{reason: :unknown_message}, 1000
    end
  end
end
