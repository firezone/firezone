defmodule PortalAPI.Client.SocketTest do
  use PortalAPI.ChannelCase, async: true

  import ExUnit.CaptureLog
  import PortalAPI.Client.Socket, only: [id: 1]
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.TokenFixtures
  import Portal.DeviceFixtures
  import Portal.DeviceTrustFixtures
  import Portal.FeaturesFixtures
  import Portal.SubjectFixtures
  import Portal.TrustAnchorFixtures
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

      # Attrs without token param, but with other required fields. The legacy
      # firezone_id wire name must keep working.
      attrs =
        valid_client_attrs()
        |> Map.take([:firezone_id])
        |> then(fn attrs -> %{"firezone_id" => attrs.firezone_id} end)
        |> Map.put("public_key", Portal.DeviceFixtures.generate_public_key())

      connect_info = build_connect_info(token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Map.fetch!(socket.assigns, :client)
      assert client.firezone_id == attrs["firezone_id"]
    end

    test "accepts external_id as the public parameter name" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs =
        valid_client_attrs()
        |> Map.take([:firezone_id])
        |> then(fn attrs ->
          %{
            "external_id" => attrs.firezone_id,
            "public_key" => Portal.DeviceFixtures.generate_public_key()
          }
        end)

      connect_info = build_connect_info(token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Map.fetch!(socket.assigns, :client)
      assert client.firezone_id == attrs["external_id"]
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

    test "renders error when public_key is missing" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = %{"token" => encoded_token}
      connect_info = build_connect_info()

      assert {:error, changeset} = connect(Socket, attrs, connect_info: connect_info)

      errors = Portal.Changeset.errors_to_string(changeset)
      assert errors =~ "public_key: can't be blank"
    end

    test "renders error when external_id is missing" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = %{
        "token" => encoded_token,
        "public_key" => Portal.DeviceFixtures.generate_public_key()
      }

      connect_info = build_connect_info()

      assert {:error, changeset} = connect(Socket, attrs, connect_info: connect_info)

      errors = Portal.Changeset.errors_to_string(changeset)
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

      assert client.firezone_id == attrs["external_id"]
      assert socket.assigns.client_version == "1.3.0"

      assert is_reference(socket.assigns.session_ref)
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == connect_info.user_agent
      assert client.last_seen_remote_ip == @client_remote_ip
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
        Portal.Authentication.create_non_interactive_client_token(
          actor,
          %{expires_at: in_one_minute},
          admin_subject
        )

      encoded_token = Portal.Authentication.encode_fragment!(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info(ip: @client_remote_ip, token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.firezone_id == attrs["external_id"]
      assert socket.assigns.client_version == "1.3.0"

      assert is_reference(socket.assigns.session_ref)
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == connect_info.user_agent
      assert client.last_seen_remote_ip == @client_remote_ip
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

    test "reuses existing client on reconnect" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      # Create existing client
      existing_client = client_fixture(account: account, actor: actor)

      # Create a new token for same actor
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.firezone_id)
      connect_info = build_connect_info()

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert socket.assigns.client.id == existing_client.id

      client = socket.assigns.client
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

      existing_device =
        Portal.Repo.get_by!(Portal.Device,
          id: existing_client.id,
          account_id: existing_client.account_id
        )

      original_ipv4 = existing_device.ipv4
      original_ipv6 = existing_device.ipv6

      # Create a new token for same actor
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.firezone_id)
      connect_info = build_connect_info()

      # Reconnect
      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = socket.assigns.client

      # Verify IPs are preserved
      assert client.ipv4 == original_ipv4
      assert client.ipv6 == original_ipv6
    end

    test "uses region code to put default coordinates" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      # Create existing client
      existing_client = client_fixture(account: account, actor: actor)

      # Create a new token for same actor
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.firezone_id)
      ip = unique_ip()
      connect_info = build_connect_info(ip: ip, x_headers: [{"x-geo-location-region", "UA"}])

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert socket.assigns.client.id == existing_client.id

      client = socket.assigns.client
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

    test "uses socket rate limit config overrides for repeated connection attempts" do
      Portal.Config.put_env_override(:portal, PortalAPI.Sockets.RateLimit,
        refill_rate: 1,
        capacity: 3
      )

      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)
      ip = unique_ip()
      connect_info = build_connect_info(ip: ip, token: encoded_token)

      # All 3 connections should succeed, proving capacity=3 is applied
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)

      # Subsequent connections should be rate limited. Use Enum.any? to avoid
      # flakiness from crossing second boundaries with the slow (1/s) refill rate.
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

    test "returns error when users_limit_exceeded is true" do
      account = account_fixture()
      update_account(account, %{users_limit_exceeded: true})

      actor = actor_fixture(account: account, type: :account_user)
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info(token: encoded_token)

      assert connect(Socket, attrs, connect_info: connect_info) == {:error, :limits_exceeded}
    end

    test "allows connection when seats_limit_exceeded is true (soft limit)" do
      account = account_fixture()
      update_account(account, %{seats_limit_exceeded: true})

      actor = actor_fixture(account: account, type: :account_user)
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info(token: encoded_token)

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
    end

    test "returns error when service_accounts_limit_exceeded is true" do
      account = account_fixture()
      update_account(account, %{service_accounts_limit_exceeded: true})

      actor = actor_fixture(account: account, type: :account_user)
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info(token: encoded_token)

      assert connect(Socket, attrs, connect_info: connect_info) == {:error, :limits_exceeded}
    end

    test "allows connection when only sites_limit_exceeded is true" do
      account = account_fixture()
      update_account(account, %{sites_limit_exceeded: true})

      actor = actor_fixture(account: account, type: :account_user)
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info(token: encoded_token)

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
    end

    test "allows connection when only admins_limit_exceeded is true" do
      account = account_fixture()
      update_account(account, %{admins_limit_exceeded: true})

      actor = actor_fixture(account: account, type: :account_user)
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info(token: encoded_token)

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
    end

    test "applies the session onto the client on successful connect" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)
      connect_info = build_connect_info(ip: @client_remote_ip, token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      client = socket.assigns.client

      assert is_reference(socket.assigns.session_ref)
      assert client.client_token_id == token.id
      assert client.last_seen_user_agent == connect_info.user_agent
      assert client.last_seen_remote_ip == @client_remote_ip
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_at
    end

    test "takes the client's reported hardware identifiers on connect" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      existing_client =
        client_fixture(
          account: account,
          actor: actor,
          device_serial: "OLD_SERIAL",
          device_uuid: "OLD_UUID"
        )

      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs =
        connect_attrs(
          token: encoded_token,
          external_id: existing_client.firezone_id,
          device_serial: "NEW_SERIAL",
          device_uuid: "NEW_UUID"
        )

      assert {:ok, socket} = connect(Socket, attrs, connect_info: build_connect_info())
      assert socket.assigns.client.id == existing_client.id
      assert socket.assigns.client.device_serial == "NEW_SERIAL"
      assert socket.assigns.client.device_uuid == "NEW_UUID"
    end
  end

  describe "connect/3 device attestation" do
    setup :setup_device_trust

    test "attests the device from the presented certificate", %{pki: pki, token: token} do
      connect_info = attested_connect_info(pki, token)

      assert {:ok, socket} = connect(Socket, connect_attrs([]), connect_info: connect_info)
      assert socket.assigns.client.attested?
      assert socket.assigns.client.last_attested_device_serial == "C02XK1ZGJGH5"
      assert socket.assigns.client.last_attested_cert_fingerprint
    end
  end

  describe "connect/3 X.509 authentication" do
    setup :setup_device_trust

    test "authenticates from X.509 identity claims without a client token", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      provider = x509_provider_fixture(account: account, is_disabled: false)

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, actor)
        )

      assert {:ok, socket} = connect(Socket, connect_attrs([]), connect_info: connect_info)
      assert socket.assigns.subject.actor.id == actor.id
      assert %Portal.Authentication.Credential.X509{} = socket.assigns.subject.credential
      assert socket.assigns.subject.credential.auth_provider_id == provider.id
      assert socket.assigns.subject.expires_at.microsecond == {0, 6}
      assert socket.assigns.client.attested?
      assert is_nil(socket.assigns.client.client_token_id)
    end

    test "authenticates a service account from an X.509 actor ID claim", %{
      account: account,
      pki: pki
    } do
      actor = actor_fixture(account: account, type: :service_account)
      provider = x509_provider_fixture(account: account, is_disabled: false)

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_actor_id_cert(pki, account, actor)
        )

      assert {:ok, socket} = connect(Socket, connect_attrs([]), connect_info: connect_info)
      assert socket.assigns.subject.actor.id == actor.id
      assert socket.assigns.subject.actor.type == :service_account
      assert %Portal.Authentication.Credential.X509{} = socket.assigns.subject.credential
      assert socket.assigns.subject.credential.auth_provider_id == provider.id
      assert socket.assigns.client.attested?
      assert is_nil(socket.assigns.client.client_token_id)
    end

    test "prefers an X.509 actor ID claim over an email claim", %{
      account: account,
      actor: email_actor,
      pki: pki
    } do
      actor = actor_fixture(account: account, type: :service_account)
      _provider = x509_provider_fixture(account: account, is_disabled: false)

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_actor_id_cert(pki, account, actor, email_actor.email)
        )

      assert {:ok, socket} = connect(Socket, connect_attrs([]), connect_info: connect_info)
      assert socket.assigns.subject.actor.id == actor.id
    end

    test "does not fall back to email when an X.509 actor ID claim is invalid", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      _provider = x509_provider_fixture(account: account, is_disabled: false)

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_actor_id_cert(pki, account, %{id: "%ZZ"}, actor.email)
        )

      assert capture_log(fn ->
               assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                        {:error, :invalid_x509_identity}
             end) =~ "invalid_x509_identity"
    end

    test "does not fall back to a token when only one X.509 identity claim is present", %{
      account: account,
      actor: actor,
      pki: pki,
      token: token
    } do
      for identity_uris <- [
            ["firezone://account-id/#{account.id}"],
            ["firezone://email/#{actor.email}"]
          ] do
        certificate = x509_authentication_cert(pki, identity_uris)
        assert_invalid_x509_identity(certificate, token)
      end
    end

    test "does not fall back to a token when an X.509 identity claim is malformed", %{
      account: account,
      actor: actor,
      pki: pki,
      token: token
    } do
      for identity_uris <- [
            ["firezone://account-id/not-a-uuid", "firezone://email/#{actor.email}"],
            ["firezone://account-id", "firezone://email/#{actor.email}"],
            ["firezone://account-id/#{account.id}", "firezone://email/"]
          ] do
        certificate = x509_authentication_cert(pki, identity_uris)
        assert_invalid_x509_identity(certificate, token)
      end
    end

    test "rejects two distinct X.509 account ID claims", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      other_account = account_fixture()
      _provider = x509_provider_fixture(account: account, is_disabled: false)

      certificate =
        x509_authentication_cert(pki, [
          "firezone://account-id/#{account.id}",
          "firezone://account-id/#{other_account.id}",
          "firezone://email/#{actor.email}"
        ])

      assert_invalid_x509_identity(certificate)
    end

    test "rejects two distinct X.509 email claims when authenticating by email", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      other_actor = actor_fixture(account: account)
      _provider = x509_provider_fixture(account: account, is_disabled: false)

      certificate =
        x509_authentication_cert(pki, [
          "firezone://account-id/#{account.id}",
          "firezone://email/#{actor.email}",
          "firezone://email/#{other_actor.email}"
        ])

      assert_invalid_x509_identity(certificate)
    end

    test "rejects two distinct X.509 actor ID claims", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      other_actor = actor_fixture(account: account, type: :service_account)
      _provider = x509_provider_fixture(account: account, is_disabled: false)

      certificate =
        x509_authentication_cert(pki, [
          "firezone://account-id/#{account.id}",
          "firezone://actor-id/#{actor.id}",
          "firezone://actor-id/#{other_actor.id}"
        ])

      assert_invalid_x509_identity(certificate)
    end

    test "scopes an X.509 actor ID claim to the claimed account", %{
      account: account,
      pki: pki
    } do
      other_account = account_fixture()
      actor = actor_fixture(account: other_account, type: :service_account)
      _provider = x509_provider_fixture(account: account, is_disabled: false)

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_actor_id_cert(pki, account, actor)
        )

      log =
        capture_log(fn ->
          assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                   {:error, :x509_user_not_found}
        end)

      assert log =~ "x509_user_not_found"
      assert log =~ "account_id=#{account.id}"
      assert log =~ "actor_id=#{actor.id}"
    end

    test "normalizes the certificate email before matching the actor", %{
      account: account,
      pki: pki
    } do
      actor = actor_fixture(account: account, email: "User@bücher.example")
      _provider = x509_provider_fixture(account: account, is_disabled: false)

      # URI SANs are IA5 strings, so the Unicode domain arrives percent-encoded.
      certificate_actor = %{actor | email: "USER@b%C3%BCcher.example"}

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, certificate_actor)
        )

      assert {:ok, socket} = connect(Socket, connect_attrs([]), connect_info: connect_info)
      assert socket.assigns.subject.actor.id == actor.id
    end

    test "a certificate X.509 identity takes precedence over an invalid bearer token", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      provider = x509_provider_fixture(account: account, is_disabled: false)

      connect_info =
        build_connect_info(
          token: "invalid",
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, actor)
        )

      assert {:ok, socket} = connect(Socket, connect_attrs([]), connect_info: connect_info)
      assert socket.assigns.subject.credential.auth_provider_id == provider.id
      assert %Portal.Authentication.Credential.X509{} = socket.assigns.subject.credential
    end

    test "requires a client token when the certificate lacks X.509 identity claims", %{pki: pki} do
      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: client_cert(pki, :rsa)
        )

      assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
               {:error, :missing_token}
    end

    test "returns a specific error when the X.509 provider is disabled", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      _provider = x509_provider_fixture(account: account, is_disabled: true)

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, actor)
        )

      assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
               {:error, :x509_authentication_disabled}
    end

    test "does not fall back to a token when the X.509 provider is disabled",
         %{
           account: account,
           actor: actor,
           pki: pki
         } do
      _provider = x509_provider_fixture(account: account, is_disabled: true)
      client_token = client_token_fixture(account: account, actor: actor)

      connect_info =
        build_connect_info(
          token: encode_token(client_token),
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, actor)
        )

      assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
               {:error, :x509_authentication_disabled}
    end

    test "does not fall back to a token when the X.509 provider is missing", %{
      account: account,
      actor: actor,
      pki: pki,
      token: token
    } do
      connect_info =
        build_connect_info(
          token: token,
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, actor)
        )

      assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
               {:error, :x509_authentication_not_found}
    end

    test "returns a specific error when the certificate account does not exist", %{
      actor: actor,
      pki: pki,
      token: token
    } do
      unknown_account = %{id: Ecto.UUID.generate()}

      connect_info =
        build_connect_info(
          token: token,
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, unknown_account, actor)
        )

      assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
               {:error, :x509_account_not_found}
    end

    test "returns a specific error when the certificate account is disabled", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      _provider = x509_provider_fixture(account: account, is_disabled: false)
      account |> Ecto.Changeset.change(is_disabled: true) |> Repo.update!()

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, actor)
        )

      assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
               {:error, :x509_account_disabled}
    end

    test "returns a specific error when no active user matches the certificate", %{
      account: account,
      actor: actor,
      pki: pki,
      token: token
    } do
      _provider = x509_provider_fixture(account: account, is_disabled: false)
      unknown_actor = %{actor | email: "unknown@example.com"}

      connect_info =
        build_connect_info(
          token: token,
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, unknown_actor)
        )

      log =
        capture_log(fn ->
          assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                   {:error, :x509_user_not_found}
        end)

      assert log =~ "x509_user_not_found"
      assert log =~ "account_id=#{account.id}"
      assert log =~ "email=#{unknown_actor.email}"
    end

    test "returns a specific error when the certificate user is disabled", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      _provider = x509_provider_fixture(account: account, is_disabled: false)
      actor |> Ecto.Changeset.change(is_disabled: true) |> Repo.update!()

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, actor)
        )

      log =
        capture_log(fn ->
          assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                   {:error, :x509_user_disabled}
        end)

      assert log =~ "x509_user_disabled"
      assert log =~ "account_id=#{account.id}"
      assert log =~ "email=#{actor.email}"
    end

    test "returns a specific error when the certificate actor type is not allowed", %{
      account: account,
      pki: pki
    } do
      actor = actor_fixture(account: account, type: :api_client)
      _provider = x509_provider_fixture(account: account, is_disabled: false)

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_actor_id_cert(pki, account, actor)
        )

      assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
               {:error, :x509_user_type_not_allowed}
    end

    test "returns a trust-anchor error when trust anchors are globally disabled", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      _provider = x509_provider_fixture(account: account, is_disabled: false)
      disable_feature(:trust_anchors)

      connect_info =
        build_connect_info(
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, actor)
        )

      assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
               {:error, :no_trust_anchors}
    end

    test "refuses a connect through the mutual-TLS host without a certificate", %{token: token} do
      connect_info = build_connect_info(token: token, host: "mtls.firezone.test")

      assert capture_log(fn ->
               assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                        {:error, :device_untrusted}
             end) =~ "no_certificate_presented"
    end

    test "refuses a certificate that does not chain to an anchor", %{pki: pki, token: token} do
      connect_info =
        build_connect_info(
          token: token,
          host: "mtls.firezone.test",
          client_cert: client_cert(pki, :untrusted)
        )

      assert capture_log(fn ->
               assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                        {:error, :device_untrusted}
             end) =~ "untrusted_chain"
    end

    test "refuses a connect through the mutual-TLS host when the account has no anchors", %{
      pki: pki
    } do
      account = account_fixture()
      actor = actor_fixture(account: account)
      token = client_token_fixture(account: account, actor: actor)
      connect_info = attested_connect_info(pki, encode_token(token))

      assert capture_log(fn ->
               assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                        {:error, :device_untrusted}
             end) =~ "no_trust_anchors"
    end

    test "does not fall back to a valid token when an X.509 identity has no trust anchors", %{
      pki: pki
    } do
      account = account_fixture()
      actor = actor_fixture(account: account)
      _provider = x509_provider_fixture(account: account, is_disabled: false)
      token = client_token_fixture(account: account, actor: actor)

      connect_info =
        build_connect_info(
          token: encode_token(token),
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(pki, account, actor)
        )

      assert capture_log(fn ->
               assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                        {:error, :no_trust_anchors}
             end) =~ "no_trust_anchors"
    end

    test "validates an X.509 certificate before looking up its claimed user", %{
      account: account,
      actor: actor,
      token: token
    } do
      _provider = x509_provider_fixture(account: account, is_disabled: false)
      unknown_actor = %{actor | email: "unknown@example.com"}
      untrusted_pki = pki()

      connect_info =
        build_connect_info(
          token: token,
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(untrusted_pki, account, unknown_actor)
        )

      log =
        capture_log(fn ->
          assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                   {:error, :untrusted_chain}
        end)

      assert log =~ "untrusted_chain"
      refute log =~ "x509_user_not_found"
    end

    test "rate limits failed X.509 authentication before repeating validation", %{
      account: account,
      actor: actor
    } do
      _provider = x509_provider_fixture(account: account, is_disabled: false)
      untrusted_pki = pki()
      ip = unique_ip()

      connect_info =
        build_connect_info(
          ip: ip,
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(untrusted_pki, account, actor)
        )

      assert capture_log(fn ->
               assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                        {:error, :untrusted_chain}
             end) =~ "untrusted_chain"

      connect_info_with_bogus_token =
        build_connect_info(
          ip: ip,
          token: "attacker-controlled-token",
          host: "mtls.firezone.test",
          client_cert: x509_identity_cert(untrusted_pki, account, actor)
        )

      # Use Enum.any? to avoid flakiness from crossing second boundaries with the
      # slow (1/s) refill rate.
      rate_limited =
        Enum.any?(1..3, fn _ ->
          connect(Socket, connect_attrs([]), connect_info: connect_info_with_bogus_token) ==
            {:error, :rate_limit}
        end)

      assert rate_limited, "Expected the repeated X.509 failure to be rate limited"
    end
  end

  describe "connect/3 device trust" do
    setup :setup_device_trust

    test "connects unattested on the plain API host", %{pki: pki, token: token} do
      connect_info =
        build_connect_info(
          token: token,
          host: "api.firezone.test",
          client_cert: client_cert(pki, :rsa)
        )

      assert {:ok, socket} = connect(Socket, connect_attrs([]), connect_info: connect_info)
      refute socket.assigns.client.attested?
      assert is_nil(socket.assigns.client.last_attested_device_serial)
    end

    test "every client socket enforces the mutual-TLS host", %{
      account: account,
      actor: actor,
      pki: pki
    } do
      for socket_module <- [Socket, PortalAPI.Client.V2.Socket] do
        token = client_token_fixture(account: account, actor: actor)
        attrs = connect_attrs([])

        assert {:ok, socket} =
                 connect(socket_module, attrs,
                   connect_info: attested_connect_info(pki, encode_token(token))
                 )

        assert socket.assigns.client.attested?

        bare_token = client_token_fixture(account: account, actor: actor)

        connect_info =
          build_connect_info(token: encode_token(bare_token), host: "mtls.firezone.test")

        assert capture_log(fn ->
                 assert connect(socket_module, attrs, connect_info: connect_info) ==
                          {:error, :device_untrusted}
               end) =~ "no_certificate_presented"
      end
    end

    test "merges a reinstalled client back onto its attested device row", %{
      account: account,
      actor: actor,
      pki: pki,
      token: token
    } do
      existing =
        client_fixture(
          account: account,
          actor: actor,
          firezone_id: "fz-old",
          last_attested_device_serial: "C02XK1ZGJGH5",
          last_attested_mdm_device_id: "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
        )

      connect_info = attested_connect_info(pki, token)
      attrs = connect_attrs(external_id: "fz-new")

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert socket.assigns.client.id == existing.id
      assert is_nil(socket.assigns.client.firezone_id)
    end
  end

  describe "id/1" do
    test "creates a channel for a client" do
      subject = subject_fixture(type: :client)
      socket = socket(PortalAPI.Client.Socket, "", %{subject: subject})

      assert id(socket) == "socket:#{subject.credential.id}"
    end
  end

  describe "resolve_client/4" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)
      %{account: account, actor: actor, subject: subject}
    end

    test "an unattested connect resolves by firezone_id", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      existing = client_fixture(account: account, actor: actor, firezone_id: "fz-same")

      changeset =
        device_trust_changeset(account, actor, %{
          "name" => "Same Client",
          "firezone_id" => "fz-same"
        })

      assert {:ok, client, false} = Socket.Database.resolve_client(changeset, nil, subject)
      assert client.id == existing.id
    end

    test "an unattested connect with no match inserts a new device", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-1"})

      assert {:ok, client, false} = Socket.Database.resolve_client(changeset, nil, subject)
      assert client.firezone_id == "fz-1"
      assert is_nil(client.last_attested_at)
    end

    test "an unattested connect never reaches an attested row", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      attested =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_cert_fingerprint: "fp-3",
          firezone_id: nil,
          last_attested_mdm_device_id: "mdm-1",
          last_attested_at: DateTime.utc_now()
        )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "Impostor", "firezone_id" => "fz-x"})

      assert {:ok, client, false} = Socket.Database.resolve_client(changeset, nil, subject)
      refute client.id == attested.id
    end

    test "the MDM device id is unique per actor", %{account: account, actor: actor} do
      client_fixture(
        account: account,
        actor: actor,
        last_attested_mdm_device_id: "mdm-dup",
        firezone_id: "fz-a"
      )

      assert {:error, changeset} =
               device_trust_changeset(account, actor, %{
                 "name" => "Duplicate",
                 "firezone_id" => "fz-b",
                 "last_attested_mdm_device_id" => "mdm-dup"
               })
               |> Portal.Safe.unscoped()
               |> Portal.Safe.insert()

      assert {"has already been taken", _} = changeset.errors[:last_attested_mdm_device_id]
    end

    test "a hardware serial may repeat across rows", %{account: account, actor: actor} do
      client_fixture(
        account: account,
        actor: actor,
        last_attested_device_serial: "SN-SHARED",
        last_attested_mdm_device_id: "mdm-first",
        last_attested_cert_fingerprint: "fp-5",
          firezone_id: nil
      )

      assert {:ok, _client} =
               device_trust_changeset(account, actor, %{
                 "name" => "Re-enrolled",
                 "last_attested_device_serial" => "SN-SHARED",
                 "last_attested_mdm_device_id" => "mdm-second",
                 "last_attested_cert_fingerprint" => "fp-second"
               })
               |> Portal.Safe.unscoped()
               |> Portal.Safe.insert()
    end
  end

  describe "resolve_client/4 device-trust proof" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)
      %{account: account, actor: actor, subject: subject}
    end

    test "persists proven identifiers and pinned cert onto the row", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-1"})

      proof = %{
        identifiers: %{
          last_attested_device_serial: "C02XK1ZGJGH5",
          last_attested_mdm_device_id: "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
        },
        last_attested_cert_serial: "4A2F008C",
        last_attested_cert_fingerprint: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert {:ok, client, true} = resolve_with_proof(changeset, proof, subject)
      assert client.last_attested_device_serial == "C02XK1ZGJGH5"
      assert client.last_attested_mdm_device_id == "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
      assert client.last_attested_cert_fingerprint == proof.last_attested_cert_fingerprint
      # Recorded so a revocation learned after this connect can still find the
      # row: a certificate serial only identifies a certificate with its issuer.
      assert client.last_attested_cert_issuer == proof.last_attested_cert_issuer
    end

    test "a new MDM device id enrolls as a new row", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      # Re-enrolment mints a new MDM device id. The hardware identifiers are
      # self-reported at enrollment, so they are attributes rather than a way
      # to relocate the device onto its old row.
      existing =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "SN-REENROLL",
          last_attested_mdm_device_id: "mdm-old",
          last_attested_cert_fingerprint: "fp-6",
          firezone_id: nil
        )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-1"})

      proof = %{
        identifiers: %{
          last_attested_device_serial: "SN-REENROLL",
          last_attested_mdm_device_id: "mdm-new"
        },
        last_attested_cert_serial: "AA",
        last_attested_cert_fingerprint: "bb",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert {:ok, client, true} = resolve_with_proof(changeset, proof, subject)
      refute client.id == existing.id
      assert client.last_attested_mdm_device_id == "mdm-new"
      assert client.last_attested_device_serial == "SN-REENROLL"
      assert is_nil(client.firezone_id)
    end

    test "the same MDM device id keeps its row", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      existing =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "SN-KEEP",
          last_attested_mdm_device_id: "mdm-keep",
          firezone_id: "fz-old"
        )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-new"})

      proof = %{
        identifiers: %{
          last_attested_device_serial: "SN-KEEP",
          last_attested_device_uuid: "uuid-learned",
          last_attested_mdm_device_id: "mdm-keep"
        },
        last_attested_cert_serial: "AA",
        last_attested_cert_fingerprint: "bb",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert {:ok, client, true} = resolve_with_proof(changeset, proof, subject)
      assert client.id == existing.id
      assert client.last_attested_device_uuid == "uuid-learned"
      assert is_nil(client.firezone_id)
    end

    test "a certificate with no MDM device id resolves by its pinned certificate", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      # Mosyle exposes only a serial number variable, so its certificates carry
      # no MDM device id and the pinned certificate is the only identity left.
      existing =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "SN-MOSYLE",
          last_attested_cert_fingerprint: "fp-mosyle",
          last_attested_cert_serial: "4A2F008C",
          last_attested_cert_issuer: <<"issuer-der">>,
          firezone_id: nil
        )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-new"})

      proof = %{
        identifiers: %{last_attested_device_serial: "SN-MOSYLE"},
        last_attested_cert_serial: "4A2F008C",
        last_attested_cert_fingerprint: "fp-mosyle",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert {:ok, client, true} = resolve_with_proof(changeset, proof, subject)
      assert client.id == existing.id
      assert is_nil(client.last_attested_mdm_device_id)
    end

    test "a renewed certificate with no MDM device id enrolls as a new row", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      existing =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "SN-RENEW",
          last_attested_cert_fingerprint: "fp-old",
          last_attested_cert_serial: "OLDSERIAL",
          last_attested_cert_issuer: <<"issuer-der">>,
          firezone_id: nil
        )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-new"})

      proof = %{
        identifiers: %{last_attested_device_serial: "SN-RENEW"},
        last_attested_cert_serial: "NEWSERIAL",
        last_attested_cert_fingerprint: "fp-new",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert {:ok, client, true} = resolve_with_proof(changeset, proof, subject)
      refute client.id == existing.id
    end

    test "the MDM device id wins over the pinned certificate", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      by_mdm =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: "mdm-wins",
          last_attested_cert_fingerprint: "fp-8",
          firezone_id: nil
        )

      by_cert =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_cert_fingerprint: "fp-shared",
          last_attested_cert_serial: "AA",
          last_attested_cert_issuer: <<"issuer-der">>,
          firezone_id: nil
        )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-new"})

      proof = %{
        identifiers: %{last_attested_mdm_device_id: "mdm-wins"},
        last_attested_cert_serial: "AA",
        last_attested_cert_fingerprint: "fp-shared",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert {:ok, client, true} = resolve_with_proof(changeset, proof, subject)
      assert client.id == by_mdm.id
      refute client.id == by_cert.id
    end

    test "a device with only an MDM id enrolls as a new row on re-enrollment", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      existing =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: "mdm-only-old",
          firezone_id: "fz-android"
        )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-android"})

      proof = %{
        identifiers: %{last_attested_mdm_device_id: "mdm-only-new"},
        last_attested_cert_serial: "AA",
        last_attested_cert_fingerprint: "bb",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert {:ok, client, true} = resolve_with_proof(changeset, proof, subject)
      refute client.id == existing.id
      assert client.last_attested_mdm_device_id == "mdm-only-new"
      assert is_nil(client.firezone_id)
    end

    test "an attested connect never adopts a row matched only by firezone_id", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      existing =
        client_fixture(
          account: account,
          actor: actor,
          firezone_id: "fz-shared",
          last_attested_device_serial: "SN-VICTIM",
          last_attested_mdm_device_id: "mdm-victim"
        )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-shared"})

      proof = %{
        identifiers: %{last_attested_mdm_device_id: "mdm-attacker"},
        last_attested_cert_serial: "AA",
        last_attested_cert_fingerprint: "bb",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert {:ok, client, true} = resolve_with_proof(changeset, proof, subject)
      refute client.id == existing.id
      assert is_nil(client.last_attested_device_serial)
      assert is_nil(client.firezone_id)
    end

    test "refuses a pinned certificate whose row claims a different MDM device id", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      # The same certificate always asserts the same identifiers, so a row
      # holding this certificate while naming a different device was rewritten
      # by something other than a connect. Adopting it would move that row's
      # identity on the strength of whatever did the rewriting.
      client_fixture(
        account: account,
        actor: actor,
        last_attested_mdm_device_id: "mdm-was",
        last_attested_cert_fingerprint: "fp-shared",
        last_attested_cert_serial: "AA",
        last_attested_cert_issuer: <<"issuer-der">>,
        firezone_id: nil
      )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-1"})

      proof = %{
        identifiers: %{last_attested_mdm_device_id: "mdm-now"},
        last_attested_cert_serial: "AA",
        last_attested_cert_fingerprint: "fp-shared",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert resolve_with_proof(changeset, proof, subject) ==
                        {:error, :device_identity_conflict}
             end) =~ "contradicts the device row"
    end

    test "refuses a pinned certificate that no longer asserts an identifier the row holds", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      # Same certificate, so its identifiers cannot have changed. Reading one
      # fewer than last time means we read the same bytes worse, and clearing a
      # proven identifier on the strength of that is not done quietly.
      client_fixture(
        account: account,
        actor: actor,
        last_attested_mdm_device_id: "mdm-known",
        last_attested_cert_fingerprint: "fp-lossy",
        last_attested_cert_serial: "CC",
        last_attested_cert_issuer: <<"issuer-der">>,
        firezone_id: nil
      )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-3"})

      proof = %{
        identifiers: %{last_attested_device_serial: "SN-1"},
        last_attested_cert_serial: "CC",
        last_attested_cert_fingerprint: "fp-lossy",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert resolve_with_proof(changeset, proof, subject) ==
                        {:error, :device_identity_conflict}
             end) =~ "contradicts the device row"
    end

    test "refuses a pinned certificate asserting an identifier the row never recorded", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      # Same certificate, so reading an identifier out of it now that we did not
      # read before is our parsing changing under a row, not the device changing.
      # Fixing the parsing is what repairs the row; adopting on a changed read is
      # how a row quietly takes on an identity nothing re-proved.
      client_fixture(
        account: account,
        actor: actor,
        last_attested_cert_fingerprint: "fp-repair",
        last_attested_cert_serial: "BB",
        last_attested_cert_issuer: <<"issuer-der">>,
        firezone_id: nil
      )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-2"})

      proof = %{
        identifiers: %{last_attested_mdm_device_id: "mdm-learned"},
        last_attested_cert_serial: "BB",
        last_attested_cert_fingerprint: "fp-repair",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert resolve_with_proof(changeset, proof, subject) ==
                        {:error, :device_identity_conflict}
             end) =~ "contradicts the device row"
    end

    test "refuses the connect when the certificate contradicts a hardware id", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      client_fixture(
        account: account,
        actor: actor,
        last_attested_device_serial: "SN-1",
        last_attested_device_uuid: "uuid-1",
        last_attested_mdm_device_id: "mdm-1",
        last_attested_cert_fingerprint: "fp-11",
          firezone_id: nil
      )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-new"})

      proof = %{
        identifiers: %{
          last_attested_device_serial: "SN-1",
          last_attested_device_uuid: "uuid-2",
          last_attested_mdm_device_id: "mdm-1"
        },
        last_attested_cert_serial: "AA",
        last_attested_cert_fingerprint: "bb",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert resolve_with_proof(changeset, proof, subject) ==
                   {:error, :device_identity_conflict}
        end)

      assert log =~ "contradicts the device row"
    end

    test "a certificate that drops a hardware id clears it rather than refusing", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      # Which identifiers an MDM emits is a profile setting, so a certificate
      # that stops asserting one must not strand the device.
      existing =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "SN-2",
          last_attested_device_uuid: "uuid-gone",
          last_attested_mdm_device_id: "mdm-2",
          last_attested_cert_fingerprint: "fp-12",
          firezone_id: nil
        )

      changeset =
        device_trust_changeset(account, actor, %{"name" => "New", "firezone_id" => "fz-new"})

      proof = %{
        identifiers: %{
          last_attested_device_serial: "SN-2",
          last_attested_mdm_device_id: "mdm-2"
        },
        last_attested_cert_serial: "AA",
        last_attested_cert_fingerprint: "bb",
        last_attested_cert_issuer: <<"issuer-der">>
      }

      assert {:ok, client, true} = resolve_with_proof(changeset, proof, subject)
      assert client.id == existing.id
      assert is_nil(client.last_attested_device_uuid)
      assert client.last_attested_device_serial == "SN-2"
    end
  end

  # The device row and how it was matched are resolved by the attestation read,
  # so these tests run that read rather than feeding the answer in by hand.
  defp resolve_with_proof(changeset, proof, subject) do
    state =
      PortalAPI.Client.DeviceTrust.Database.attestation_state(
        proof.last_attested_cert_issuer,
        proof.last_attested_cert_serial,
        Map.get(proof.identifiers, :last_attested_mdm_device_id),
        subject
      )

    proof = Map.merge(proof, %{device: state.device, matched_on: state.matched_on})

    Socket.Database.resolve_client(changeset, proof, subject)
  end

  defp device_trust_changeset(account, actor, attrs) do
    %Portal.Device{}
    |> Ecto.Changeset.cast(attrs, [
      :name,
      :firezone_id,
      :last_attested_device_serial,
      :last_attested_device_uuid,
      :last_attested_mdm_device_id,
      :last_attested_cert_fingerprint
    ])
    |> Ecto.Changeset.put_change(:type, :client)
    |> Ecto.Changeset.put_change(:account_id, account.id)
    |> Ecto.Changeset.put_change(:actor_id, actor.id)
    |> Portal.Device.changeset()
  end

  defp connect_attrs(attrs) do
    valid_client_attrs()
    |> then(fn attrs -> %{external_id: attrs.firezone_id} end)
    |> Map.put(:public_key, Portal.DeviceFixtures.generate_public_key())
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp setup_device_trust(_context) do
    Portal.Config.put_env_override(:portal, :mtls_external_url, "https://mtls.firezone.test/")

    account = account_fixture()
    enable_feature(:trust_anchors)
    pki = pki()
    trust_anchor_fixture(account: account, certs: [pki.ca_der])

    actor = actor_fixture(account: account)
    token = client_token_fixture(account: account, actor: actor)

    %{account: account, actor: actor, pki: pki, token: encode_token(token)}
  end

  defp assert_invalid_x509_identity(certificate, token \\ nil) do
    connect_info =
      build_connect_info(token: token, host: "mtls.firezone.test", client_cert: certificate)

    assert capture_log(fn ->
             assert connect(Socket, connect_attrs([]), connect_info: connect_info) ==
                      {:error, :invalid_x509_identity}
           end) =~ "invalid_x509_identity"
  end

  defp attested_connect_info(pki, token) do
    build_connect_info(
      token: token,
      host: "mtls.firezone.test",
      client_cert: client_cert(pki, :rsa)
    )
  end

  defp x509_identity_cert(pki, account, actor) do
    x509_authentication_cert(pki, [
      "firezone://account-id/#{account.id}",
      "firezone://email/#{actor.email}"
    ])
  end

  defp x509_actor_id_cert(pki, account, actor, email \\ nil) do
    identity_uris = [
      "firezone://account-id/#{account.id}",
      "firezone://actor-id/#{actor.id}"
    ]

    identity_uris = if email, do: identity_uris ++ ["firezone://email/#{email}"], else: identity_uris

    x509_authentication_cert(pki, identity_uris)
  end

  defp x509_authentication_cert(pki, identity_uris) do
    identity_sans =
      Enum.map(identity_uris, fn uri ->
        {:uniformResourceIdentifier, String.to_charlist(uri)}
      end)

    leaf(pki,
      sans: identity_sans ++ [{:uniformResourceIdentifier, ~c"firezone://serial/C02XK1ZGJGH5"}]
    )
  end
end
