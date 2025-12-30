defmodule PortalAPI.Relay.SocketTest do
  use PortalAPI.ChannelCase, async: true
  import PortalAPI.Relay.Socket, except: [connect: 3]
  import Portal.TokenFixtures
  import Portal.RelayFixtures
  alias PortalAPI.Relay.Socket

  @connlib_version "1.3.0"

  @connect_info %{
    user_agent: "iOS/12.7 (iPhone) connlib/#{@connlib_version}",
    peer_data: %{address: {189, 172, 73, 001}},
    x_headers: [
      {"x-forwarded-for", "189.172.73.153"},
      {"x-geo-location-region", "Ukraine"},
      {"x-geo-location-city", "Kyiv"},
      {"x-geo-location-coordinates", "50.4333,30.5167"}
    ],
    trace_context_headers: []
  }

  describe "connect/3" do
    test "returns error when token is missing" do
      assert connect(Socket, %{}, connect_info: @connect_info) == {:error, :missing_token}
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

      assert {:ok, socket} = connect(Socket, attrs, connect_info: @connect_info)
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

      connect_info = %{@connect_info | x_headers: [{"x-geo-location-region", "UA"}]}

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

      connect_info = %{@connect_info | trace_context_headers: trace_context_headers}

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
      assert span_ctx != OpenTelemetry.Tracer.current_span_ctx()
    end

    test "returns error when token is invalid" do
      attrs = %{"token" => "foo", "ipv4" => "100.64.1.1"}
      assert connect(Socket, attrs, connect_info: @connect_info) == {:error, :invalid_token}
    end

    test "returns error when no IP is provided" do
      token = relay_token_fixture()
      encrypted_secret = encode_relay_token(token)

      attrs = %{"token" => encrypted_secret}
      assert connect(Socket, attrs, connect_info: @connect_info) == {:error, :missing_ip}
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
end
