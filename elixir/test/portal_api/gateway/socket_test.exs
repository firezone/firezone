defmodule PortalAPI.Gateway.SocketTest do
  use PortalAPI.ChannelCase, async: true
  import PortalAPI.Gateway.Socket, except: [connect: 3]
  import Portal.AccountFixtures
  import Portal.SiteFixtures
  import Portal.GatewayFixtures
  import Portal.TokenFixtures
  import Portal.SubjectFixtures
  alias PortalAPI.Gateway.Socket

  @connlib_version "1.3.0"

  describe "connect/3" do
    setup do
      buffer =
        start_supervised!(
          {Portal.GatewaySession.Buffer, name: Portal.GatewaySession.Buffer, callers: [self()]}
        )

      %{buffer: buffer}
    end

    test "returns error when token is missing" do
      connect_info = build_connect_info()
      assert connect(Socket, %{}, connect_info: connect_info) == {:error, :missing_token}
    end

    test "accepts token from x-authorization header" do
      token = gateway_token_fixture()
      encrypted_secret = encode_gateway_token(token)

      # Attrs without token param, but with other required fields
      attrs =
        valid_gateway_attrs()
        |> Map.take([:external_id, :public_key])
        |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

      connect_info = build_connect_info(token: encrypted_secret)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert gateway = Map.fetch!(socket.assigns, :gateway)
      assert gateway.external_id == attrs["external_id"]
    end

    test "x-authorization header takes precedence over token param" do
      account = account_fixture()
      site = site_fixture(account: account)

      # Create two tokens for the same site
      token1 = gateway_token_fixture(account: account, site: site)
      encrypted_secret1 = encode_gateway_token(token1)

      token2 = gateway_token_fixture(account: account, site: site)
      encrypted_secret2 = encode_gateway_token(token2)

      # Use token1 in header, token2 in params
      attrs = connect_attrs(token: encrypted_secret2)
      connect_info = build_connect_info(token: encrypted_secret1)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      # Should use the header token (token1)
      assert socket.assigns.token_id == token1.id
    end

    test "creates a new gateway" do
      token = gateway_token_fixture()
      encrypted_secret = encode_gateway_token(token)

      attrs = connect_attrs(token: encrypted_secret)

      connect_info =
        build_connect_info(user_agent: "iOS/12.7 (iPhone) connlib/#{@connlib_version}")

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert gateway = Map.fetch!(socket.assigns, :gateway)

      assert gateway.external_id == attrs["external_id"]

      assert session = Map.fetch!(socket.assigns, :session)
      assert session.public_key == attrs["public_key"]
      assert session.user_agent == connect_info.user_agent
      assert session.remote_ip_location_region == "Ukraine"
      assert session.remote_ip_location_city == "Kyiv"
      assert session.remote_ip_location_lat == 50.4333
      assert session.remote_ip_location_lon == 30.5167
      assert session.version == @connlib_version

      Portal.GatewaySession.Buffer.flush()

      [persisted_session] = Repo.all(Portal.GatewaySession)
      assert persisted_session.gateway_id == gateway.id
      assert persisted_session.user_agent == connect_info.user_agent
      assert persisted_session.remote_ip_location_region == "Ukraine"
      assert persisted_session.remote_ip_location_city == "Kyiv"
      assert persisted_session.remote_ip_location_lat == 50.4333
      assert persisted_session.remote_ip_location_lon == 30.5167
      assert persisted_session.version == @connlib_version
    end

    test "uses region code to put default coordinates" do
      token = gateway_token_fixture()
      encrypted_secret = encode_gateway_token(token)

      attrs = connect_attrs(token: encrypted_secret)
      connect_info = build_connect_info(x_headers: [{"x-geo-location-region", "UA"}])

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert Map.fetch!(socket.assigns, :gateway)
      assert session = Map.fetch!(socket.assigns, :session)
      assert session.remote_ip_location_region == "UA"
      assert session.remote_ip_location_city == nil
      assert session.remote_ip_location_lat == 49.0
      assert session.remote_ip_location_lon == 32.0
    end

    test "propagates trace context" do
      token = gateway_token_fixture()
      encrypted_secret = encode_gateway_token(token)
      attrs = connect_attrs(token: encrypted_secret)

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

    test "reuses existing gateway on reconnect" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(account: account, site: site)
      encrypted_secret = encode_gateway_token(token)

      attrs = connect_attrs(token: encrypted_secret, external_id: gateway.external_id)
      connect_info = build_connect_info()

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert socket.assigns.gateway.id == gateway.id

      Portal.GatewaySession.Buffer.flush()

      import Ecto.Query

      session =
        from(gs in Portal.GatewaySession, where: gs.gateway_token_id == ^token.id)
        |> Repo.one!()

      assert session.gateway_id == gateway.id
      assert session.remote_ip_location_region == "Ukraine"
      assert session.remote_ip_location_city == "Kyiv"
      assert session.remote_ip_location_lat == 50.4333
      assert session.remote_ip_location_lon == 30.5167
    end

    test "preserves ipv4 and ipv6 addresses on reconnection" do
      account = account_fixture()
      site = site_fixture(account: account)

      # Create existing gateway with specific IPs
      existing_gateway = gateway_fixture(account: account, site: site)
      original_ipv4 = existing_gateway.ipv4_address.address
      original_ipv6 = existing_gateway.ipv6_address.address

      # Create a new token for same site
      token = gateway_token_fixture(account: account, site: site)
      encrypted_secret = encode_gateway_token(token)

      attrs = connect_attrs(token: encrypted_secret, external_id: existing_gateway.external_id)
      connect_info = build_connect_info()

      # Reconnect
      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert gateway = socket.assigns.gateway

      # Verify IPs are preserved
      assert gateway.ipv4_address.address == original_ipv4
      assert gateway.ipv6_address.address == original_ipv6
    end

    test "returns error when token is invalid" do
      attrs = connect_attrs(token: "foo")
      connect_info = build_connect_info()
      assert connect(Socket, attrs, connect_info: connect_info) == {:error, :invalid_token}
    end

    test "rate limits repeated connection attempts from same IP and token" do
      token = gateway_token_fixture()
      encrypted_secret = encode_gateway_token(token)

      attrs = connect_attrs(token: encrypted_secret)

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
      token = gateway_token_fixture()
      encrypted_secret = encode_gateway_token(token)

      attrs = connect_attrs(token: encrypted_secret)

      ip1 = unique_ip()
      ip2 = unique_ip()

      connect_info_1 = build_connect_info(ip: ip1, token: encrypted_secret)
      connect_info_2 = build_connect_info(ip: ip2, token: encrypted_secret)

      # Both connections from different IPs should succeed
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info_1)
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info_2)
    end

    test "allows connections from same IP with different tokens" do
      account = account_fixture()
      site = site_fixture(account: account)

      token1 = gateway_token_fixture(account: account, site: site)
      encrypted_secret1 = encode_gateway_token(token1)

      token2 = gateway_token_fixture(account: account, site: site)
      encrypted_secret2 = encode_gateway_token(token2)

      ip = unique_ip()

      attrs1 = connect_attrs(token: encrypted_secret1)
      attrs2 = connect_attrs(token: encrypted_secret2)

      connect_info_1 = build_connect_info(ip: ip, token: encrypted_secret1)
      connect_info_2 = build_connect_info(ip: ip, token: encrypted_secret2)

      # Both connections with different tokens should succeed
      assert {:ok, _socket} = connect(Socket, attrs1, connect_info: connect_info_1)
      assert {:ok, _socket} = connect(Socket, attrs2, connect_info: connect_info_2)
    end
  end

  describe "id/1" do
    test "creates a channel for a gateway" do
      subject = subject_fixture(type: :client)
      socket = socket(PortalAPI.Gateway.Socket, "", %{token_id: subject.credential.id})

      assert id(socket) == "socket:#{subject.credential.id}"
    end
  end

  defp connect_attrs(attrs) do
    valid_gateway_attrs()
    |> Map.take([:external_id, :public_key])
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
