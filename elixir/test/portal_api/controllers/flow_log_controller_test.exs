defmodule PortalAPI.FlowLogControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.FlowLogFixtures

  alias Portal.FlowLog
  alias Portal.FlowLogToken

  setup do
    %{account: account_fixture()}
  end

  defp expires_at, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  # Sign the request: mint the per-authorization ingest token from `claims` (the
  # attribution snapshot) and attach it as the Bearer credential. Every record in
  # the request is attributed to this single token.
  defp authorize(conn, account, claims \\ %{}) do
    token = FlowLogToken.mint(account, flow_log_token_claims(claims), expires_at())
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  # A record body: the network 6-tuple, the flow window, and the counters.
  # Attribution comes from the request token, never the body. `overrides` change
  # the body fields.
  defp build_record(overrides \\ %{}) do
    Map.merge(
      %{
        "protocol" => "tcp",
        "inner_src_ip" => "100.64.0.1",
        "inner_src_port" => 12_345,
        "inner_dst_ip" => "10.0.0.5",
        "inner_dst_port" => 443,
        "outer_src_ip" => "198.51.100.1",
        "outer_src_port" => 51_820,
        "outer_dst_ip" => "203.0.113.7",
        "outer_dst_port" => 51_820,
        "flow_start" => "2026-03-20T10:00:00.000000Z",
        "flow_end" => "2026-03-20T10:05:00.000000Z",
        "last_packet" => "2026-03-20T10:04:59.000000Z",
        "rx_packets" => 10,
        "tx_packets" => 12,
        "rx_bytes" => 1024,
        "tx_bytes" => 2048
      },
      overrides
    )
  end

  defp post_logs(conn, records) do
    post(conn, "/ingestion/flow_logs", %{"flow_logs" => records})
  end

  describe "create/2 request shape" do
    test "returns 400 when batch exceeds 10k records", %{conn: conn, account: account} do
      records = for _ <- 1..10_001, do: build_record()

      conn = conn |> authorize(account) |> post_logs(records)

      assert %{"status" => 400, "detail" => "Batch size exceeds maximum of 10000"} =
               json_response(conn, 400)
    end

    test "returns 400 when flow_logs key is missing", %{conn: conn, account: account} do
      conn = conn |> authorize(account) |> post("/ingestion/flow_logs", %{"something" => "else"})

      assert %{"status" => 400, "detail" => "Expected a \"flow_logs\" array"} =
               json_response(conn, 400)
    end

    test "returns 400 when flow_logs is not a list", %{conn: conn, account: account} do
      conn =
        conn |> authorize(account) |> post("/ingestion/flow_logs", %{"flow_logs" => "not a list"})

      assert %{"status" => 400} = json_response(conn, 400)
    end

    test "returns 422 when record is not a JSON object", %{conn: conn, account: account} do
      conn = conn |> authorize(account) |> post_logs(["not a map", 42, nil])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert errors["0"]["record"] == ["must be a JSON object"]
      assert errors["1"]["record"] == ["must be a JSON object"]
      assert errors["2"]["record"] == ["must be a JSON object"]
    end
  end

  describe "create/2 request authentication" do
    test "returns 401 when the Authorization header is missing", %{conn: conn} do
      conn = post_logs(conn, [build_record()])

      assert %{"status" => 401, "detail" => "Authentication credentials were missing or invalid."} =
               json_response(conn, 401)
    end

    test "returns 401 when the token signature is tampered", %{conn: conn, account: account} do
      token = FlowLogToken.mint(account, flow_log_token_claims(), expires_at())

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token <> "x")
        |> post_logs([build_record()])

      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "returns 401 when the token is signed with the wrong account key", %{conn: conn} do
      account = account_fixture()
      impostor = %{account | ingest_signing_key: :crypto.strong_rand_bytes(32)}
      token = FlowLogToken.mint(impostor, flow_log_token_claims(), expires_at())

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post_logs([build_record()])

      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "returns 401 when the token is expired", %{conn: conn, account: account} do
      expired =
        FlowLogToken.mint(
          account,
          flow_log_token_claims(),
          DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> expired)
        |> post_logs([build_record()])

      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "returns 401 when the token says uploads are disabled", %{conn: conn, account: account} do
      conn =
        conn
        |> authorize(account, %{"uploads_enabled" => false})
        |> post_logs([build_record()])

      assert %{
               "status" => 401,
               "detail" => "Flow log uploads are not enabled for this authorization"
             } = json_response(conn, 401)

      assert Repo.all(FlowLog) == []
    end

    test "returns 401 when the token has no uploads_enabled claim", %{
      conn: conn,
      account: account
    } do
      claims = Map.delete(flow_log_token_claims(), "uploads_enabled")
      token = FlowLogToken.mint(account, claims, expires_at())

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post_logs([build_record()])

      assert %{"status" => 401} = json_response(conn, 401)
    end
  end

  describe "create/2 single policy authorization" do
    test "returns 422 when records reference more than one authz id", %{
      conn: conn,
      account: account
    } do
      authz_id = Ecto.UUID.generate()

      records = [
        build_record(),
        build_record(%{"policy_authorization_id" => Ecto.UUID.generate()})
      ]

      conn =
        conn
        |> authorize(account, %{"policy_authorization_id" => authz_id})
        |> post_logs(records)

      assert %{"status" => 422, "detail" => detail} = json_response(conn, 422)
      assert detail == "All flow logs in a request must belong to a single policy authorization"
      assert Repo.all(FlowLog) == []
    end

    test "accepts records that match the token's authz id and persists it", %{
      conn: conn,
      account: account
    } do
      authz_id = Ecto.UUID.generate()

      conn =
        conn
        |> authorize(account, %{"policy_authorization_id" => authz_id})
        |> post_logs([build_record(%{"policy_authorization_id" => authz_id})])

      assert %{"data" => %{"status" => "ok"}} = json_response(conn, 200)

      [log] = Repo.all(FlowLog)
      assert log.policy_authorization_id == authz_id
    end

    test "a record omitting the authz id is attributed to the token", %{
      conn: conn,
      account: account
    } do
      authz_id = Ecto.UUID.generate()

      conn =
        conn
        |> authorize(account, %{"policy_authorization_id" => authz_id})
        |> post_logs([build_record()])

      assert %{"data" => %{"status" => "ok"}} = json_response(conn, 200)

      [log] = Repo.all(FlowLog)
      assert log.policy_authorization_id == authz_id
    end
  end

  describe "create/2 persistence" do
    test "returns 200 and persists attribution from the token", %{conn: conn, account: account} do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()
      auth_provider_id = Ecto.UUID.generate()

      conn =
        authorize(conn, account, %{
          "device_id" => device_id,
          "resource_id" => resource_id,
          "policy_id" => policy_id,
          "actor_id" => actor_id,
          "auth_provider_id" => auth_provider_id,
          "resource_name" => "prod-db",
          "resource_address" => "10.0.0.5",
          "actor_email" => "user@example.com",
          "actor_name" => "Some User"
        })

      conn = post_logs(conn, [build_record()])

      assert %{"data" => %{"status" => "ok"}} = json_response(conn, 200)

      [log] = Repo.all(FlowLog)
      assert log.account_id == account.id
      assert log.device_id == device_id
      assert log.role == :initiator
      assert log.resource_id == resource_id
      assert log.policy_id == policy_id
      assert log.auth_provider_id == auth_provider_id
      assert log.resource_name == "prod-db"
      assert log.resource_address == "10.0.0.5"
      assert log.actor_id == actor_id
      assert log.actor_email == "user@example.com"
      assert log.actor_name == "Some User"
      assert log.protocol == :tcp
      assert log.inner_dst_port == 443
    end

    test "preserves microsecond precision on authorized_at from the token", %{
      conn: conn,
      account: account
    } do
      conn = authorize(conn, account, %{"authorized_at" => "2026-03-20T09:59:00.123456Z"})

      assert %{"data" => %{"status" => "ok"}} =
               post_logs(conn, [build_record()]) |> json_response(200)

      [log] = Repo.all(FlowLog)
      assert log.authorized_at == ~U[2026-03-20 09:59:00.123456Z]
    end

    test "persists the connecting client's device telemetry from the token", %{
      conn: conn,
      account: account
    } do
      device_uuid = Ecto.UUID.generate()
      identifier_for_vendor = Ecto.UUID.generate()

      conn =
        authorize(conn, account, %{
          "client_version" => "1.5.1",
          "device_os_name" => "Android",
          "device_os_version" => "14",
          "device_serial" => "SN-9000",
          "device_uuid" => device_uuid,
          "device_identifier_for_vendor" => identifier_for_vendor,
          "device_firebase_installation_id" => "fId-xyz789"
        })

      post_logs(conn, [build_record()])

      [log] = Repo.all(FlowLog)
      assert log.client_version == "1.5.1"
      assert log.device_os_name == "Android"
      assert log.device_os_version == "14"
      assert log.device_serial == "SN-9000"
      assert log.device_uuid == device_uuid
      assert log.device_identifier_for_vendor == identifier_for_vendor
      assert log.device_firebase_installation_id == "fId-xyz789"
    end

    test "the body cannot override the token's attribution", %{conn: conn, account: account} do
      device_id = Ecto.UUID.generate()

      conn = authorize(conn, account, %{"device_id" => device_id})

      record =
        build_record(%{
          # These body keys must be ignored; attribution comes from the token.
          "device_id" => Ecto.UUID.generate(),
          "role" => "responder",
          "account_id" => Ecto.UUID.generate()
        })

      post_logs(conn, [record])

      [log] = Repo.all(FlowLog)
      assert log.device_id == device_id
      assert log.role == :initiator
      assert log.account_id == account.id
    end

    test "network fields and counters land in typed columns", %{conn: conn, account: account} do
      record =
        build_record(%{
          "rx_bytes" => 2048,
          "tx_bytes" => 512,
          "rx_packets" => 7,
          "tx_packets" => 9,
          "domain" => "db.example.com",
          "outer_src_ip" => "198.51.100.9",
          "last_packet" => "2026-03-20T10:04:30.000000Z"
        })

      conn |> authorize(account) |> post_logs([record])

      [log] = Repo.all(FlowLog)
      assert log.rx_bytes == 2048
      assert log.tx_bytes == 512
      assert log.rx_packets == 7
      assert log.tx_packets == 9
      assert log.domain == "db.example.com"
      assert log.outer_src_ip == %Postgrex.INET{address: {198, 51, 100, 9}}
      assert log.last_packet == ~U[2026-03-20 10:04:30.000000Z]
    end

    test "a batch of distinct flows under one authorization is persisted", %{
      conn: conn,
      account: account
    } do
      records = for i <- 1..3, do: build_record(%{"inner_src_port" => 1000 + i})

      conn |> authorize(account) |> post_logs(records)

      logs = Repo.all(FlowLog)
      assert length(logs) == 3
      assert Enum.all?(logs, &(&1.account_id == account.id))
    end

    test "initiator and responder for the same device create two rows", %{
      conn: _conn,
      account: account
    } do
      device_id = Ecto.UUID.generate()

      build_conn()
      |> authorize(account, %{"device_id" => device_id, "role" => "initiator"})
      |> post_logs([build_record()])

      build_conn()
      |> authorize(account, %{"device_id" => device_id, "role" => "responder"})
      |> post_logs([build_record()])

      logs = Repo.all(FlowLog)
      assert length(logs) == 2
      assert Enum.sort(Enum.map(logs, & &1.role)) == [:initiator, :responder]
    end

    test "two devices reporting the same flow create two rows", %{conn: _conn, account: account} do
      build_conn()
      |> authorize(account, %{"device_id" => Ecto.UUID.generate(), "role" => "initiator"})
      |> post_logs([build_record()])

      build_conn()
      |> authorize(account, %{"device_id" => Ecto.UUID.generate(), "role" => "responder"})
      |> post_logs([build_record()])

      assert length(Repo.all(FlowLog)) == 2
    end
  end

  describe "create/2 incremental reporting" do
    test "an open record (no flow_end) is accepted and later completed", %{
      conn: _conn,
      account: account
    } do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      claims = %{"device_id" => device_id, "resource_id" => resource_id}

      open = build_record(%{"flow_end" => nil, "tx_bytes" => 100})

      assert %{"data" => %{"status" => "ok"}} =
               build_conn() |> authorize(account, claims) |> post_logs([open]) |> json_response(200)

      [log] = Repo.all(FlowLog)
      assert is_nil(log.flow_end)
      assert log.tx_bytes == 100
      open_seq = log.seq

      close = build_record(%{"flow_end" => "2026-03-20T10:05:00.000000Z", "tx_bytes" => 999})

      assert %{"data" => %{"status" => "ok"}} =
               build_conn() |> authorize(account, claims) |> post_logs([close]) |> json_response(200)

      [log] = Repo.all(FlowLog)
      assert log.flow_end == ~U[2026-03-20 10:05:00.000000Z]
      assert log.tx_bytes == 999
      assert log.seq > open_seq
      assert log.start_seq == open_seq
    end

    test "replaying a closed record is idempotent", %{conn: _conn, account: account} do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      claims = %{"device_id" => device_id, "resource_id" => resource_id}
      record = build_record()

      assert build_conn() |> authorize(account, claims) |> post_logs([record]) |> json_response(200)
      [%{seq: seq}] = Repo.all(FlowLog)

      assert build_conn() |> authorize(account, claims) |> post_logs([record]) |> json_response(200)

      assert [%{seq: ^seq}] = Repo.all(FlowLog)
    end

    test "a late open does not wipe an existing close", %{conn: _conn, account: account} do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      claims = %{"device_id" => device_id, "resource_id" => resource_id}

      close = build_record(%{"flow_end" => "2026-03-20T10:05:00.000000Z"})
      build_conn() |> authorize(account, claims) |> post_logs([close])

      open = build_record(%{"flow_end" => nil})
      build_conn() |> authorize(account, claims) |> post_logs([open])

      [log] = Repo.all(FlowLog)
      assert log.flow_end == ~U[2026-03-20 10:05:00.000000Z]
    end
  end

  describe "create/2 distinct flows" do
    test "two flows sharing a slot with different 6-tuples both persist", %{
      conn: _conn,
      account: account
    } do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      claims = %{"device_id" => device_id, "resource_id" => resource_id}

      first = build_record(%{"inner_dst_port" => 443})
      build_conn() |> authorize(account, claims) |> post_logs([first])

      # Same (device, role, flow_start) but a different 6-tuple: a distinct
      # parallel flow, not a conflict.
      second = build_record(%{"inner_dst_port" => 8443})

      assert build_conn() |> authorize(account, claims) |> post_logs([second]) |> json_response(200)

      ports = Repo.all(FlowLog) |> Enum.map(& &1.inner_dst_port) |> Enum.sort()
      assert ports == [443, 8443]
    end

    test "within-batch flows sharing a slot with different 6-tuples both persist", %{
      conn: conn,
      account: account
    } do
      records = [
        build_record(%{"inner_dst_port" => 443}),
        build_record(%{"inner_dst_port" => 8443})
      ]

      assert conn |> authorize(account) |> post_logs(records) |> json_response(200)

      ports = Repo.all(FlowLog) |> Enum.map(& &1.inner_dst_port) |> Enum.sort()
      assert ports == [443, 8443]
    end
  end

  describe "create/2 validation" do
    test "returns 422 with invalid role", %{conn: conn, account: account} do
      conn = conn |> authorize(account, %{"role" => "sideways"}) |> post_logs([build_record()])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "0")
    end

    test "returns 422 with invalid protocol", %{conn: conn, account: account} do
      conn = conn |> authorize(account) |> post_logs([build_record(%{"protocol" => "sctp"})])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "0")
    end

    test "returns 422 with invalid inner_src_ip", %{conn: conn, account: account} do
      conn = conn |> authorize(account) |> post_logs([build_record(%{"inner_src_ip" => "not-an-ip"})])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "0")
    end

    test "accepts a skewed flow_end before flow_start", %{conn: conn, account: account} do
      record =
        build_record(%{
          "flow_start" => "2026-03-20T10:05:00.000000Z",
          "flow_end" => "2026-03-20T10:00:00.000000Z"
        })

      assert %{"data" => %{"status" => "ok"}} =
               conn |> authorize(account) |> post_logs([record]) |> json_response(200)

      [log] = Repo.all(FlowLog)
      assert log.flow_start == ~U[2026-03-20 10:05:00.000000Z]
      assert log.flow_end == ~U[2026-03-20 10:00:00.000000Z]
    end

    test "accepts a skewed flow_start before authorized_at", %{conn: conn, account: account} do
      conn = authorize(conn, account, %{"authorized_at" => "2026-03-20T10:01:00.000000Z"})
      record = build_record(%{"flow_start" => "2026-03-20T10:00:00.000000Z"})

      assert %{"data" => %{"status" => "ok"}} =
               post_logs(conn, [record]) |> json_response(200)

      [log] = Repo.all(FlowLog)
      assert log.flow_start == ~U[2026-03-20 10:00:00.000000Z]
      assert log.authorized_at == ~U[2026-03-20 10:01:00.000000Z]
    end

    test "rejects and logs an over-large counter", %{conn: conn, account: account} do
      bigint_max = 9_223_372_036_854_775_807
      record = build_record(%{"rx_bytes" => bigint_max + 1})

      logged =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = conn |> authorize(account) |> post_logs([record])
          assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
          assert Map.has_key?(errors, "0")
        end)

      assert logged =~ "exceeds the bigint maximum"
      assert Repo.all(FlowLog) == []
    end

    test "accepts a nil resource_address for address-less resources", %{
      conn: conn,
      account: account
    } do
      conn = authorize(conn, account, %{"resource_address" => nil})

      assert %{"data" => %{"status" => "ok"}} =
               post_logs(conn, [build_record()]) |> json_response(200)

      [log] = Repo.all(FlowLog)
      assert is_nil(log.resource_address)
    end

    test "returns 422 when a close is missing its counters", %{conn: conn, account: account} do
      record =
        build_record(%{
          "flow_end" => "2026-03-20T10:05:00.000000Z",
          "rx_bytes" => nil
        })

      conn = conn |> authorize(account) |> post_logs([record])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "0")
    end

    test "partial batch inserts valid records and returns 422", %{conn: conn, account: account} do
      good = build_record(%{"inner_src_port" => 1111})
      bad = build_record(%{"inner_src_port" => 2222, "protocol" => "sctp"})

      conn = conn |> authorize(account) |> post_logs([good, bad])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "1")
      assert length(Repo.all(FlowLog)) == 1
    end
  end
end
