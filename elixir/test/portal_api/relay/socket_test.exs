defmodule PortalAPI.Relay.SocketTest do
  use PortalAPI.ChannelCase, async: true
  import ExUnit.CaptureLog
  import PortalAPI.Relay.Socket, except: [connect: 3]
  import Portal.TokenFixtures
  import Portal.RelayFixtures
  alias PortalAPI.Relay.Socket

  describe "connect/3" do
    test "returns error when token is missing" do
      connect_info = build_connect_info()
      assert connect(Socket, %{}, connect_info: connect_info) == {:error, :missing_token}
    end

    test "accepts token from x-authorization header" do
      token = relay_token_fixture()
      encrypted_secret = encode_relay_token(token)

      # Attrs without token param
      attrs = %{
        "ipv4" => "100.64.1.1",
        "ipv6" => "2001:db8::1",
        "port" => 3478
      }

      connect_info = build_connect_info(token: encrypted_secret)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert relay = Map.fetch!(socket.assigns, :relay)
      assert relay.ipv4 == "100.64.1.1"
    end

    test "x-authorization header takes precedence over token param" do
      # Create two tokens
      token1 = relay_token_fixture()
      encrypted_secret1 = encode_relay_token(token1)

      token2 = relay_token_fixture()
      encrypted_secret2 = encode_relay_token(token2)

      # Use token1 in header, token2 in params
      attrs = %{
        "token" => encrypted_secret2,
        "ipv4" => "100.64.1.1"
      }

      connect_info = build_connect_info(token: encrypted_secret1)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      # Should use the header token (token1)
      assert socket.assigns.token_id == token1.id
    end

    test "builds a relay from connection params" do
      token = relay_token_fixture()
      encrypted_secret = encode_relay_token(token)

      attrs = %{
        "token" => encrypted_secret,
        "ipv4" => "100.64.1.1",
        "ipv6" => "2001:db8::1",
        "port" => 3478
      }

      connect_info = build_connect_info()

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert relay = Map.fetch!(socket.assigns, :relay)

      assert relay.ipv4 == "100.64.1.1"
      assert relay.ipv6 == "2001:db8::1"
      assert relay.port == 3478
      assert relay.lat == 50.4333
      assert relay.lon == 30.5167
    end

    test "uses region code to put default coordinates" do
      token = relay_token_fixture()
      encrypted_secret = encode_relay_token(token)

      attrs = %{
        "token" => encrypted_secret,
        "ipv4" => "100.64.1.1"
      }

      connect_info = build_connect_info(x_headers: [{"x-geo-location-region", "UA"}])

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert relay = Map.fetch!(socket.assigns, :relay)
      assert relay.lat == 49.0
      assert relay.lon == 32.0
    end

    test "propagates trace context" do
      token = relay_token_fixture()
      encrypted_secret = encode_relay_token(token)

      attrs = %{
        "token" => encrypted_secret,
        "ipv4" => "100.64.1.1"
      }

      span_ctx = OpenTelemetry.Tracer.start_span("test")
      OpenTelemetry.Tracer.set_current_span(span_ctx)

      trace_context_headers = [
        {"traceparent", "00-a1bf53221e0be8000000000000000002-f316927eb144aa62-01"}
      ]

      base_connect_info = build_connect_info()
      connect_info = %{base_connect_info | trace_context_headers: trace_context_headers}

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
      assert span_ctx != OpenTelemetry.Tracer.current_span_ctx()
    end

    test "returns error when token is invalid" do
      attrs = %{"token" => "foo", "ipv4" => "100.64.1.1"}
      connect_info = build_connect_info()
      assert connect(Socket, attrs, connect_info: connect_info) == {:error, :invalid_token}
    end

    test "returns error when no IP is provided" do
      token = relay_token_fixture()
      encrypted_secret = encode_relay_token(token)

      attrs = %{"token" => encrypted_secret}
      connect_info = build_connect_info()
      assert connect(Socket, attrs, connect_info: connect_info) == {:error, :missing_ip}
    end

    test "rate limits repeated connection attempts from same IP and token" do
      token = relay_token_fixture()
      encrypted_secret = encode_relay_token(token)

      attrs = %{
        "token" => encrypted_secret,
        "ipv4" => "100.64.1.1"
      }

      # Use a unique IP for this test to avoid interference with other tests
      ip = unique_ip()
      connect_info = build_connect_info(ip: ip, token: encrypted_secret)

      # First connection should succeed
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)

      # Subsequent connections with same IP and token should be rate limited.
      # The rate limiter uses a 1 token/second bucket, so we try multiple times
      # to ensure we hit the rate limit even if we cross a second boundary.
      rate_limited =
        Enum.any?(1..3, fn _ ->
          connect(Socket, attrs, connect_info: connect_info) == {:error, :rate_limit}
        end)

      assert rate_limited, "Expected at least one connection attempt to be rate limited"
    end

    test "allows connections from different IPs with same token" do
      token = relay_token_fixture()
      encrypted_secret = encode_relay_token(token)

      attrs = %{
        "token" => encrypted_secret,
        "ipv4" => "100.64.1.1"
      }

      ip1 = unique_ip()
      ip2 = unique_ip()

      connect_info_1 = build_connect_info(ip: ip1, token: encrypted_secret)
      connect_info_2 = build_connect_info(ip: ip2, token: encrypted_secret)

      # Both connections from different IPs should succeed
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info_1)
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info_2)
    end

    test "allows connections from same IP with different tokens" do
      token1 = relay_token_fixture()
      encrypted_secret1 = encode_relay_token(token1)

      token2 = relay_token_fixture()
      encrypted_secret2 = encode_relay_token(token2)

      ip = unique_ip()

      attrs1 = %{
        "token" => encrypted_secret1,
        "ipv4" => "100.64.1.1"
      }

      attrs2 = %{
        "token" => encrypted_secret2,
        "ipv4" => "100.64.1.2"
      }

      connect_info_1 = build_connect_info(ip: ip, token: encrypted_secret1)
      connect_info_2 = build_connect_info(ip: ip, token: encrypted_secret2)

      # Both connections with different tokens should succeed
      assert {:ok, _socket} = connect(Socket, attrs1, connect_info: connect_info_1)
      assert {:ok, _socket} = connect(Socket, attrs2, connect_info: connect_info_2)
    end
  end

  describe "id/1" do
    test "returns socket id based on token_id" do
      relay = relay_fixture()
      token_id = Ecto.UUID.generate()
      socket = socket(PortalAPI.Relay.Socket, "", %{relay: relay, token_id: token_id})

      assert id(socket) == "socket:#{token_id}"
    end
  end

  describe "terminate/2" do
    test "logs warning when connection times out" do
      relay = relay_fixture()
      socket = socket(PortalAPI.Relay.Socket, "", %{relay: relay})

      log =
        capture_log(fn ->
          assert :ok = Socket.terminate(:timeout, {%{}, socket})
        end)

      assert log =~ "Relay missed heartbeat"
      assert log =~ relay.ipv4
      assert log =~ relay.ipv6
    end

    test "does not log for other termination reasons" do
      relay = relay_fixture()
      socket = socket(PortalAPI.Relay.Socket, "", %{relay: relay})

      log =
        capture_log(fn ->
          assert :ok = Socket.terminate(:shutdown, {%{}, socket})
        end)

      refute log =~ "Relay missed heartbeat"
    end
  end
end
