defmodule API.Gateway.SocketTest do
  use API.ChannelCase, async: true
  import API.Gateway.Socket, except: [connect: 3]
  alias API.Gateway.Socket

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

    test "creates a new gateway" do
      token = Fixtures.Sites.create_token()
      encrypted_secret = Domain.Crypto.encode_token_fragment!(token)

      attrs = connect_attrs(token: encrypted_secret)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: @connect_info)
      assert gateway = Map.fetch!(socket.assigns, :gateway)

      assert gateway.external_id == attrs["external_id"]
      assert gateway.public_key == attrs["public_key"]
      assert gateway.last_seen_user_agent == @connect_info.user_agent
      assert gateway.last_seen_remote_ip.address == {189, 172, 73, 153}
      assert gateway.last_seen_remote_ip_location_region == "Ukraine"
      assert gateway.last_seen_remote_ip_location_city == "Kyiv"
      assert gateway.last_seen_remote_ip_location_lat == 50.4333
      assert gateway.last_seen_remote_ip_location_lon == 30.5167
      assert gateway.last_seen_version == @connlib_version
    end

    test "uses region code to put default coordinates" do
      token = Fixtures.Sites.create_token()
      encrypted_secret = Domain.Crypto.encode_token_fragment!(token)

      attrs = connect_attrs(token: encrypted_secret)

      connect_info = %{@connect_info | x_headers: [{"x-geo-location-region", "UA"}]}

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert gateway = Map.fetch!(socket.assigns, :gateway)
      assert gateway.last_seen_remote_ip_location_region == "UA"
      assert gateway.last_seen_remote_ip_location_city == nil
      assert gateway.last_seen_remote_ip_location_lat == 49.0
      assert gateway.last_seen_remote_ip_location_lon == 32.0
    end

    test "propagates trace context" do
      token = Fixtures.Sites.create_token()
      encrypted_secret = Domain.Crypto.encode_token_fragment!(token)
      attrs = connect_attrs(token: encrypted_secret)

      span_ctx = OpenTelemetry.Tracer.start_span("test")
      OpenTelemetry.Tracer.set_current_span(span_ctx)

      trace_context_headers = [
        {"traceparent", "00-a1bf53221e0be8000000000000000002-f316927eb144aa62-01"}
      ]

      connect_info = %{@connect_info | trace_context_headers: trace_context_headers}

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
      assert span_ctx != OpenTelemetry.Tracer.current_span_ctx()
    end

    test "updates existing gateway" do
      account = Fixtures.Accounts.create_account()
      site = Fixtures.Sites.create_site(account: account)
      gateway = Fixtures.Gateways.create_gateway(account: account, site: site)
      token = Fixtures.Sites.create_token(account: account, site: site)
      encrypted_secret = Domain.Crypto.encode_token_fragment!(token)

      attrs = connect_attrs(token: encrypted_secret, external_id: gateway.external_id)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: @connect_info)
      assert gateway = Repo.one(Domain.Gateways.Gateway)
      assert gateway.id == socket.assigns.gateway.id
    end

    test "returns error when token is invalid" do
      attrs = connect_attrs(token: "foo")
      assert connect(Socket, attrs, connect_info: @connect_info) == {:error, :invalid_token}
    end
  end

  describe "id/1" do
    test "creates a channel for a gateway" do
      subject = Fixtures.Auth.create_subject(type: :client)
      socket = socket(API.Gateway.Socket, "", %{token_id: subject.token_id})

      assert id(socket) == "sessions:#{subject.token_id}"
    end
  end

  defp connect_attrs(attrs) do
    Fixtures.Gateways.gateway_attrs()
    |> Map.take(~w[external_id public_key]a)
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
