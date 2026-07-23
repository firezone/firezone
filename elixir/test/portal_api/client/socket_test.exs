defmodule PortalAPI.Client.SocketTest do
  use PortalAPI.ChannelCase, async: true

  import PortalAPI.Client.Socket, only: [id: 1]
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures
  import Portal.DeviceFixtures
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

    test "logs warning when hardware identifiers mismatch" do
      import ExUnit.CaptureLog

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

      connect_info = build_connect_info()

      log =
        capture_log(fn ->
          assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
        end)

      assert log =~ "Hardware ID mismatch"
      assert log =~ "device_serial"
      assert log =~ "device_uuid"
    end
  end

  describe "id/1" do
    test "creates a channel for a client" do
      subject = subject_fixture(type: :client)
      socket = socket(PortalAPI.Client.Socket, "", %{subject: subject})

      assert id(socket) == "socket:#{subject.credential.id}"
    end
  end

  describe "find_or_create_client/2" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      %{account: account, actor: actor}
    end

    test "attested identifier match wins over firezone_id and merges it in memory", %{
      account: account,
      actor: actor
    } do
      existing =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "SN-ATT-1",
          firezone_id: "fz-old"
        )

      changeset =
        device_trust_changeset(account, actor, %{
          "name" => "Reinstalled Client",
          "firezone_id" => "fz-new",
          "last_attested_device_serial" => "SN-ATT-1"
        })

      assert {:ok, client} = Socket.Database.find_or_create_client(changeset, %{})
      assert client.id == existing.id
      assert client.firezone_id == "fz-new"
      assert [_only_one] = Portal.Repo.all(actor_devices_query(account, actor))

      # The connect path is write-free: the merged firezone_id is persisted by
      # the batched client session flush, not here.
      db_row = Portal.Repo.get_by!(Portal.Device, id: existing.id, account_id: account.id)
      assert db_row.firezone_id == "fz-old"
    end

    test "attested identifiers with no match insert a new device", %{
      account: account,
      actor: actor
    } do
      changeset =
        device_trust_changeset(account, actor, %{
          "name" => "New Client",
          "firezone_id" => "fz-1",
          "last_attested_device_serial" => "SN-NEW-1"
        })

      assert {:ok, client} = Socket.Database.find_or_create_client(changeset, %{})
      assert client.last_attested_device_serial == "SN-NEW-1"
      assert client.firezone_id == "fz-1"
    end

    test "without attested identifiers the firezone_id lookup is unchanged", %{
      account: account,
      actor: actor
    } do
      existing = client_fixture(account: account, actor: actor, firezone_id: "fz-same")

      changeset =
        device_trust_changeset(account, actor, %{
          "name" => "Same Client",
          "firezone_id" => "fz-same"
        })

      assert {:ok, client} = Socket.Database.find_or_create_client(changeset, %{})
      assert client.id == existing.id
    end

    test "attested identifiers are unique per actor", %{account: account, actor: actor} do
      client_fixture(
        account: account,
        actor: actor,
        last_attested_device_serial: "SN-DUP",
        firezone_id: "fz-a"
      )

      assert {:error, changeset} =
               device_trust_changeset(account, actor, %{
                 "name" => "Duplicate",
                 "firezone_id" => "fz-b",
                 "last_attested_device_serial" => "SN-DUP"
               })
               |> Portal.Safe.unscoped()
               |> Portal.Safe.insert()

      assert {"has already been taken", _} = changeset.errors[:last_attested_device_serial]
    end

    test "identifiers split across devices refuse adoption and fall back", %{
      account: account,
      actor: actor
    } do
      # Serial matches device A, UUID matches device B: nothing can prove
      # which physical device is connecting, so neither row is adopted.
      device_a =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_serial: "SN-SPLIT",
          firezone_id: "fz-a"
        )

      device_b =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_device_uuid: "uuid-split",
          firezone_id: "fz-b"
        )

      changeset =
        device_trust_changeset(account, actor, %{
          "name" => "Ambiguous Client",
          "firezone_id" => "fz-new",
          "last_attested_device_serial" => "SN-SPLIT",
          "last_attested_device_uuid" => "uuid-split"
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, client} = Socket.Database.find_or_create_client(changeset, %{})

          # Falls back to the firezone_id path: a fresh row, with the attested
          # fields stripped so the insert cannot collide with A's or B's
          # unique indexes.
          assert client.id != device_a.id
          assert client.id != device_b.id
          assert client.firezone_id == "fz-new"
          assert is_nil(client.last_attested_device_serial)
          assert is_nil(client.last_attested_device_uuid)
        end)

      assert log =~ "split across multiple devices"
    end
  end

  defp device_trust_changeset(account, actor, attrs) do
    %Portal.Device{}
    |> Ecto.Changeset.cast(attrs, [
      :name,
      :firezone_id,
      :last_attested_device_serial,
      :last_attested_device_uuid,
      :last_attested_mdm_device_id
    ])
    |> Ecto.Changeset.put_change(:type, :client)
    |> Ecto.Changeset.put_change(:account_id, account.id)
    |> Ecto.Changeset.put_change(:actor_id, actor.id)
    |> Portal.Device.changeset()
  end

  defp actor_devices_query(account, actor) do
    import Ecto.Query

    from(d in Portal.Device,
      where: d.account_id == ^account.id and d.actor_id == ^actor.id and d.type == :client
    )
  end

  defp connect_attrs(attrs) do
    valid_client_attrs()
    |> then(fn attrs -> %{external_id: attrs.firezone_id} end)
    |> Map.put(:public_key, Portal.DeviceFixtures.generate_public_key())
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
