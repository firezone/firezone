defmodule PortalAPI.Client.SocketTest do
  use PortalAPI.ChannelCase, async: true
  import PortalAPI.Client.Socket, only: [id: 1]
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures
  import Portal.ClientFixtures
  import Portal.SubjectFixtures
  alias PortalAPI.Client.Socket

  # The actual client IP used for tests that verify remote_ip tracking
  @client_remote_ip {189, 172, 73, 153}

  describe "connect/3" do
    test "returns error when token is missing" do
      connect_info = build_connect_info()
      assert connect(Socket, %{}, connect_info: connect_info) == {:error, :missing_token}
    end

    test "accepts token from x-authorization header" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      # Attrs without token param, but with other required fields
      attrs =
        valid_client_attrs()
        |> Map.take([:external_id, :public_key])
        |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

      connect_info = build_connect_info(token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Map.fetch!(socket.assigns, :client)
      assert client.external_id == attrs["external_id"]
    end

    test "x-authorization header takes precedence over token param" do
      # Create two tokens
      token1 = client_token_fixture()
      encoded_token1 = encode_token(token1)

      token2 = client_token_fixture()
      encoded_token2 = encode_token(token2)

      # Use token1 in header, token2 in params
      attrs = connect_attrs(token: encoded_token2)
      connect_info = build_connect_info(token: encoded_token1)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      # Should use the header token (token1)
      assert socket.assigns.subject.credential.id == token1.id
    end

    test "returns error when token is invalid" do
      attrs = connect_attrs(token: "foo")
      connect_info = build_connect_info()
      assert connect(Socket, attrs, connect_info: connect_info) == {:error, :invalid_token}
    end

    test "renders error on invalid attrs" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = %{"token" => encoded_token}
      connect_info = build_connect_info()

      assert {:error, changeset} = connect(Socket, attrs, connect_info: connect_info)

      errors = Portal.Changeset.errors_to_string(changeset)
      assert errors =~ "public_key: can't be blank"
      assert errors =~ "external_id: can't be blank"
    end

    test "returns error when token is created for a different context" do
      # api_client tokens should not be usable for client socket
      token = api_token_fixture()
      encoded_token = encode_api_token(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info()

      assert connect(Socket, attrs, connect_info: connect_info) == {:error, :invalid_token}
    end

    test "creates a new client for user identity" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info(ip: @client_remote_ip, token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.external_id == attrs["external_id"]
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == connect_info.user_agent
      assert client.last_seen_remote_ip.address == @client_remote_ip
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
      assert client.last_seen_version == "1.3.0"
    end

    test "creates a new client for service account identity" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :service_account)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      in_one_minute = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, token} =
        Portal.Authentication.create_headless_client_token(
          actor,
          %{expires_at: in_one_minute},
          admin_subject
        )

      encoded_token = Portal.Authentication.encode_fragment!(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info(ip: @client_remote_ip, token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.external_id == attrs["external_id"]
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == connect_info.user_agent
      assert client.last_seen_remote_ip.address == @client_remote_ip
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
      assert client.last_seen_version == "1.3.0"
    end

    test "propagates trace context" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      span_ctx = OpenTelemetry.Tracer.start_span("test")
      OpenTelemetry.Tracer.set_current_span(span_ctx)

      attrs = connect_attrs(token: encoded_token)
      base_connect_info = build_connect_info()

      trace_context_headers = [
        {"traceparent", "00-a1bf53221e0be8000000000000000002-f316927eb144aa62-01"}
      ]

      connect_info = %{base_connect_info | trace_context_headers: trace_context_headers}

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
      assert span_ctx != OpenTelemetry.Tracer.current_span_ctx()
    end

    test "updates existing client" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      # Create existing client
      existing_client = client_fixture(account: account, actor: actor)

      # Create a new token for same actor
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.external_id)
      connect_info = build_connect_info()

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Repo.one(Portal.Client)
      assert client.id == socket.assigns.client.id
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
    end

    test "preserves ipv4 and ipv6 addresses on reconnection" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      # Create existing client with specific IPs
      existing_client = client_fixture(account: account, actor: actor)
      original_ipv4 = existing_client.ipv4_address.address
      original_ipv6 = existing_client.ipv6_address.address

      # Create a new token for same actor
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.external_id)
      connect_info = build_connect_info()

      # Reconnect
      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = socket.assigns.client

      # Verify IPs are preserved
      assert client.ipv4_address.address == original_ipv4
      assert client.ipv6_address.address == original_ipv6
    end

    test "uses region code to put default coordinates" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      # Create existing client
      existing_client = client_fixture(account: account, actor: actor)

      # Create a new token for same actor
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.external_id)
      ip = unique_ip()
      connect_info = build_connect_info(ip: ip, x_headers: [{"x-geo-location-region", "UA"}])

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Repo.one(Portal.Client)
      assert client.id == socket.assigns.client.id
      assert client.last_seen_remote_ip_location_region == "UA"
      assert client.last_seen_remote_ip_location_city == nil
      assert client.last_seen_remote_ip_location_lat == 49.0
      assert client.last_seen_remote_ip_location_lon == 32.0
    end

    test "rate limits repeated connection attempts from same IP and token" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)

      # Use a unique IP for this test to avoid interference with other tests
      ip = unique_ip()
      connect_info = build_connect_info(ip: ip, token: encoded_token)

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
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)

      ip1 = unique_ip()
      ip2 = unique_ip()

      connect_info_1 = build_connect_info(ip: ip1, token: encoded_token)
      connect_info_2 = build_connect_info(ip: ip2, token: encoded_token)

      # Both connections from different IPs should succeed
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info_1)
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info_2)
    end

    test "allows connections from same IP with different tokens" do
      token1 = client_token_fixture()
      encoded_token1 = encode_token(token1)

      token2 = client_token_fixture()
      encoded_token2 = encode_token(token2)

      ip = unique_ip()

      attrs1 = connect_attrs(token: encoded_token1)
      attrs2 = connect_attrs(token: encoded_token2)

      connect_info_1 = build_connect_info(ip: ip, token: encoded_token1)
      connect_info_2 = build_connect_info(ip: ip, token: encoded_token2)

      # Both connections with different tokens should succeed
      assert {:ok, _socket} = connect(Socket, attrs1, connect_info: connect_info_1)
      assert {:ok, _socket} = connect(Socket, attrs2, connect_info: connect_info_2)
    end
  end

  describe "id/1" do
    test "creates a channel for a client" do
      subject = subject_fixture(type: :client)
      socket = socket(PortalAPI.Client.Socket, "", %{subject: subject})

      assert id(socket) == "socket:#{subject.credential.id}"
    end
  end

  defp connect_attrs(attrs) do
    valid_client_attrs()
    |> Map.take([:external_id, :public_key])
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
