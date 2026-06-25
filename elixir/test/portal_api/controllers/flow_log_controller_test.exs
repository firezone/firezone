defmodule PortalAPI.FlowLogControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.FlowLogFixtures

  alias Portal.FlowLog
  alias Portal.FlowLogToken

  setup do
    %{account: account_fixture()}
  end

  defp token(account, overrides) do
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
    FlowLogToken.mint(account, flow_log_token_claims(overrides), expires_at)
  end

  # Builds a record body. `claim_overrides` change the (token) attribution;
  # `body_overrides` change the 6-tuple / window / stats.
  defp build_record(account, claim_overrides \\ %{}, body_overrides \\ %{}) do
    Map.merge(
      %{
        "token" => token(account, claim_overrides),
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
      body_overrides
    )
  end

  defp post_logs(conn, records) do
    post(conn, "/ingestion/flow_logs", %{"flow_logs" => records})
  end

  describe "create/2 request shape" do
    test "returns 400 when batch exceeds 10k records", %{conn: conn, account: account} do
      records = for _ <- 1..10_001, do: build_record(account)

      conn = post_logs(conn, records)

      assert %{"status" => 400, "detail" => "Batch size exceeds maximum of 10000"} =
               json_response(conn, 400)
    end

    test "returns 400 when flow_logs key is missing", %{conn: conn} do
      conn = post(conn, "/ingestion/flow_logs", %{"something" => "else"})

      assert %{"status" => 400, "detail" => "Expected a \"flow_logs\" array"} =
               json_response(conn, 400)
    end

    test "returns 400 when flow_logs is not a list", %{conn: conn} do
      conn = post(conn, "/ingestion/flow_logs", %{"flow_logs" => "not a list"})

      assert %{"status" => 400} = json_response(conn, 400)
    end

    test "returns 422 when record is not a JSON object", %{conn: conn} do
      conn = post_logs(conn, ["not a map", 42, nil])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert errors["0"]["record"] == ["must be a JSON object"]
      assert errors["1"]["record"] == ["must be a JSON object"]
      assert errors["2"]["record"] == ["must be a JSON object"]
    end
  end

  describe "create/2 token authentication" do
    test "returns 422 when token is missing", %{conn: conn, account: account} do
      record = build_record(account) |> Map.delete("token")

      conn = post_logs(conn, [record])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert errors["0"]["token"] == ["is malformed"]
    end

    test "returns 422 when token signature is tampered", %{conn: conn, account: account} do
      record = build_record(account)
      tampered = record["token"] <> "x"
      record = Map.put(record, "token", tampered)

      conn = post_logs(conn, [record])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert errors["0"]["token"] == ["is invalid"]
    end

    test "returns 422 when token is signed with the wrong account key", %{conn: conn} do
      account = account_fixture()
      impostor = %{account | ingest_signing_key: :crypto.strong_rand_bytes(32)}

      token =
        FlowLogToken.mint(impostor, flow_log_token_claims(%{}), DateTime.add(DateTime.utc_now(), 3600, :second))

      record = build_record(account) |> Map.put("token", token)

      conn = post_logs(conn, [record])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert errors["0"]["token"] == ["is invalid"]
    end

    test "returns 422 when token is expired", %{conn: conn, account: account} do
      expired =
        FlowLogToken.mint(account, flow_log_token_claims(%{}), DateTime.add(DateTime.utc_now(), -40 * 86_400, :second))

      record = build_record(account) |> Map.put("token", expired)

      conn = post_logs(conn, [record])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert errors["0"]["token"] == ["is expired"]
    end
  end

  describe "create/2 persistence" do
    test "returns 202 and persists attribution from the token", %{conn: conn, account: account} do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      policy_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()
      auth_provider_id = Ecto.UUID.generate()

      record =
        build_record(account, %{
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

      conn = post_logs(conn, [record])

      assert %{"data" => %{"status" => "accepted"}} = json_response(conn, 202)

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
      record = build_record(account, %{"authorized_at" => "2026-03-20T09:59:00.123456Z"})

      assert %{"data" => %{"status" => "accepted"}} =
               post_logs(conn, [record]) |> json_response(202)

      [log] = Repo.all(FlowLog)
      assert log.authorized_at == ~U[2026-03-20 09:59:00.123456Z]
    end

    test "persists the connecting client's device telemetry from the token", %{
      conn: conn,
      account: account
    } do
      device_uuid = Ecto.UUID.generate()
      identifier_for_vendor = Ecto.UUID.generate()

      record =
        build_record(account, %{
          "client_version" => "1.5.1",
          "device_os_name" => "Android",
          "device_os_version" => "14",
          "device_serial" => "SN-9000",
          "device_uuid" => device_uuid,
          "device_identifier_for_vendor" => identifier_for_vendor,
          "device_firebase_installation_id" => "fId-xyz789"
        })

      post_logs(conn, [record])

      [log] = Repo.all(FlowLog)
      assert log.client_version == "1.5.1"
      assert log.device_os_name == "Android"
      assert log.device_os_version == "14"
      assert log.device_serial == "SN-9000"
      assert log.device_uuid == device_uuid
      assert log.device_identifier_for_vendor == identifier_for_vendor
      assert log.device_firebase_installation_id == "fId-xyz789"
    end

    test "persists a batch spanning multiple accounts to the right accounts", %{
      conn: conn,
      account: account_a
    } do
      account_b = account_fixture()
      device_a = Ecto.UUID.generate()
      device_b = Ecto.UUID.generate()

      records = [
        build_record(account_a, %{"device_id" => device_a}),
        build_record(account_b, %{"device_id" => device_b})
      ]

      assert post_logs(conn, records) |> json_response(202)

      by_account = Repo.all(FlowLog) |> Map.new(&{&1.account_id, &1.device_id})
      assert by_account[account_a.id] == device_a
      assert by_account[account_b.id] == device_b
    end

    test "the body cannot override the token's attribution", %{conn: conn, account: account} do
      device_id = Ecto.UUID.generate()

      record =
        build_record(account, %{"device_id" => device_id}, %{
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
        build_record(account, %{}, %{
          "rx_bytes" => 2048,
          "tx_bytes" => 512,
          "rx_packets" => 7,
          "tx_packets" => 9,
          "domain" => "db.example.com",
          "outer_src_ip" => "198.51.100.9",
          "last_packet" => "2026-03-20T10:04:30.000000Z"
        })

      post_logs(conn, [record])

      [log] = Repo.all(FlowLog)
      assert log.rx_bytes == 2048
      assert log.tx_bytes == 512
      assert log.rx_packets == 7
      assert log.tx_packets == 9
      assert log.domain == "db.example.com"
      assert log.outer_src_ip == %Postgrex.INET{address: {198, 51, 100, 9}}
      assert log.last_packet == ~U[2026-03-20 10:04:30.000000Z]
    end

    test "batch of distinct records is persisted", %{conn: conn, account: account} do
      records =
        for i <- 1..3 do
          build_record(account, %{"device_id" => Ecto.UUID.generate()}, %{
            "inner_src_port" => 1000 + i
          })
        end

      post_logs(conn, records)

      logs = Repo.all(FlowLog)
      assert length(logs) == 3
      assert Enum.all?(logs, &(&1.account_id == account.id))
    end

    test "initiator and responder for the same device create two rows", %{
      conn: conn,
      account: account
    } do
      device_id = Ecto.UUID.generate()

      records = [
        build_record(account, %{"device_id" => device_id, "role" => "initiator"}),
        build_record(account, %{"device_id" => device_id, "role" => "responder"})
      ]

      post_logs(conn, records)

      logs = Repo.all(FlowLog)
      assert length(logs) == 2
      assert Enum.sort(Enum.map(logs, & &1.role)) == [:initiator, :responder]
    end

    test "two devices reporting the same flow create two rows", %{conn: conn, account: account} do
      records = [
        build_record(account, %{"device_id" => Ecto.UUID.generate(), "role" => "initiator"}),
        build_record(account, %{"device_id" => Ecto.UUID.generate(), "role" => "responder"})
      ]

      post_logs(conn, records)

      assert length(Repo.all(FlowLog)) == 2
    end
  end

  describe "create/2 incremental reporting" do
    test "an open record (no flow_end) is accepted and later completed", %{
      conn: conn,
      account: account
    } do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()

      open =
        build_record(account, %{"device_id" => device_id, "resource_id" => resource_id}, %{
          "flow_end" => nil,
          "tx_bytes" => 100
        })

      assert %{"data" => %{"status" => "accepted"}} =
               post_logs(conn, [open]) |> json_response(202)

      [log] = Repo.all(FlowLog)
      assert is_nil(log.flow_end)
      assert log.tx_bytes == 100

      close =
        build_record(account, %{"device_id" => device_id, "resource_id" => resource_id}, %{
          "flow_end" => "2026-03-20T10:05:00.000000Z",
          "tx_bytes" => 999
        })

      assert %{"data" => %{"status" => "accepted"}} =
               build_conn() |> post_logs([close]) |> json_response(202)

      [log] = Repo.all(FlowLog)
      assert log.flow_end == ~U[2026-03-20 10:05:00.000000Z]
      assert log.tx_bytes == 999
    end

    test "replaying a closed record is idempotent", %{conn: conn, account: account} do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()
      record = build_record(account, %{"device_id" => device_id, "resource_id" => resource_id})

      assert post_logs(conn, [record]) |> json_response(202)
      assert build_conn() |> post_logs([record]) |> json_response(202)

      assert length(Repo.all(FlowLog)) == 1
    end

    test "a late open does not wipe an existing close", %{conn: conn, account: account} do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()

      close =
        build_record(account, %{"device_id" => device_id, "resource_id" => resource_id}, %{
          "flow_end" => "2026-03-20T10:05:00.000000Z"
        })

      post_logs(conn, [close])

      open =
        build_record(account, %{"device_id" => device_id, "resource_id" => resource_id}, %{
          "flow_end" => nil
        })

      build_conn() |> post_logs([open])

      [log] = Repo.all(FlowLog)
      assert log.flow_end == ~U[2026-03-20 10:05:00.000000Z]
    end
  end

  describe "create/2 distinct flows" do
    test "two flows sharing a slot with different 6-tuples both persist", %{
      conn: conn,
      account: account
    } do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()

      first =
        build_record(account, %{"device_id" => device_id, "resource_id" => resource_id}, %{
          "inner_dst_port" => 443
        })

      post_logs(conn, [first])

      # Same (device, role, flow_start) but a different 6-tuple: a distinct
      # parallel flow, not a conflict.
      second =
        build_record(account, %{"device_id" => device_id, "resource_id" => resource_id}, %{
          "inner_dst_port" => 8443
        })

      assert build_conn() |> post_logs([second]) |> json_response(202)

      ports = Repo.all(FlowLog) |> Enum.map(& &1.inner_dst_port) |> Enum.sort()
      assert ports == [443, 8443]
    end

    test "within-batch flows sharing a slot with different 6-tuples both persist", %{
      conn: conn,
      account: account
    } do
      device_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()

      records = [
        build_record(account, %{"device_id" => device_id, "resource_id" => resource_id}, %{
          "inner_dst_port" => 443
        }),
        build_record(account, %{"device_id" => device_id, "resource_id" => resource_id}, %{
          "inner_dst_port" => 8443
        })
      ]

      assert post_logs(conn, records) |> json_response(202)

      ports = Repo.all(FlowLog) |> Enum.map(& &1.inner_dst_port) |> Enum.sort()
      assert ports == [443, 8443]
    end
  end

  describe "create/2 validation" do
    test "returns 422 with invalid role", %{conn: conn, account: account} do
      record = build_record(account, %{"role" => "sideways"})

      conn = post_logs(conn, [record])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "0")
    end

    test "returns 422 with invalid protocol", %{conn: conn, account: account} do
      record = build_record(account, %{}, %{"protocol" => "sctp"})

      conn = post_logs(conn, [record])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "0")
    end

    test "returns 422 with invalid inner_src_ip", %{conn: conn, account: account} do
      record = build_record(account, %{}, %{"inner_src_ip" => "not-an-ip"})

      conn = post_logs(conn, [record])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "0")
    end

    test "accepts a skewed flow_end before flow_start", %{conn: conn, account: account} do
      record =
        build_record(account, %{}, %{
          "flow_start" => "2026-03-20T10:05:00.000000Z",
          "flow_end" => "2026-03-20T10:00:00.000000Z"
        })

      assert %{"data" => %{"status" => "accepted"}} =
               post_logs(conn, [record]) |> json_response(202)

      [log] = Repo.all(FlowLog)
      assert log.flow_start == ~U[2026-03-20 10:05:00.000000Z]
      assert log.flow_end == ~U[2026-03-20 10:00:00.000000Z]
    end

    test "accepts a skewed flow_start before authorized_at", %{conn: conn, account: account} do
      record =
        build_record(account, %{"authorized_at" => "2026-03-20T10:01:00.000000Z"}, %{
          "flow_start" => "2026-03-20T10:00:00.000000Z"
        })

      assert %{"data" => %{"status" => "accepted"}} =
               post_logs(conn, [record]) |> json_response(202)

      [log] = Repo.all(FlowLog)
      assert log.flow_start == ~U[2026-03-20 10:00:00.000000Z]
      assert log.authorized_at == ~U[2026-03-20 10:01:00.000000Z]
    end

    test "rejects and logs an over-large counter", %{conn: conn, account: account} do
      bigint_max = 9_223_372_036_854_775_807
      record = build_record(account, %{}, %{"rx_bytes" => bigint_max + 1})

      logged =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post_logs(conn, [record])
          assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
          assert Map.has_key?(errors, "0")
        end)

      assert logged =~ "exceeds the bigint maximum"
      assert Repo.all(FlowLog) == []
    end

    test "accepts a nil resource_address for address-less resources", %{conn: conn, account: account} do
      record = build_record(account, %{"resource_address" => nil})

      assert %{"data" => %{"status" => "accepted"}} =
               post_logs(conn, [record]) |> json_response(202)

      [log] = Repo.all(FlowLog)
      assert is_nil(log.resource_address)
    end

    test "returns 422 when a close is missing its counters", %{conn: conn, account: account} do
      record =
        build_record(account, %{}, %{
          "flow_end" => "2026-03-20T10:05:00.000000Z",
          "rx_bytes" => nil
        })

      conn = post_logs(conn, [record])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "0")
    end

    test "partial batch inserts valid records and returns 422", %{conn: conn, account: account} do
      good = build_record(account, %{"device_id" => Ecto.UUID.generate()})
      bad = build_record(account, %{"device_id" => Ecto.UUID.generate()}, %{"protocol" => "sctp"})

      conn = post_logs(conn, [good, bad])

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "1")
      assert length(Repo.all(FlowLog)) == 1
    end
  end
end
