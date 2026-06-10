defmodule PortalAPI.FlowLogControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias Portal.FlowLog

  setup do
    account = account_fixture()

    %{account: account}
  end

  defp authorize_gateway(conn, account) do
    site = site_fixture(account: account)
    token = gateway_token_fixture(account: account, site: site)
    encoded = encode_gateway_token(token)

    put_req_header(conn, "authorization", "Bearer " <> encoded)
  end

  defp authorize_client(conn, account) do
    actor = actor_fixture(account: account)
    token = client_token_fixture(account: account, actor: actor)
    encoded = encode_token(token)

    put_req_header(conn, "authorization", "Bearer " <> encoded)
  end

  defp build_flow_record(overrides \\ %{}) do
    defaults = %{
      "device_id" => Ecto.UUID.generate(),
      "role" => "initiator",
      "protocol" => "tcp",
      "flow_start" => "2026-03-20T10:00:00.000000Z",
      "flow_end" => "2026-03-20T10:05:00.000000Z",
      "last_packet" => "2026-03-20T10:04:58.000000Z",
      "actor_id" => Ecto.UUID.generate(),
      "actor_name" => "Test User",
      "actor_email" => "user@example.com",
      "auth_provider_id" => Ecto.UUID.generate(),
      "resource_id" => Ecto.UUID.generate(),
      "resource_name" => "GitLab",
      "resource_address" => "gitlab.company.com",
      "inner_src_ip" => "100.64.0.1",
      "inner_dst_ip" => "10.0.0.5",
      "inner_src_port" => 54_321,
      "inner_dst_port" => 443,
      "inner_domain" => "gitlab.company.com",
      "outer_src_ip" => "203.0.113.10",
      "outer_dst_ip" => "198.51.100.5",
      "outer_src_port" => 51_820,
      "outer_dst_port" => 51_820,
      "rx_packets" => 100,
      "tx_packets" => 80,
      "rx_bytes" => 102_400,
      "tx_bytes" => 20_480
    }

    Map.merge(defaults, overrides)
  end

  describe "create/2" do
    test "returns 401 when unauthenticated", %{conn: conn} do
      conn = post(conn, "/ingestion/flow_logs", %{"flow_logs" => [build_flow_record()]})

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns 400 when batch exceeds 10k records", %{conn: conn, account: account} do
      records = for _ <- 1..10_001, do: build_flow_record()

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => records})

      assert %{
               "type" => "about:blank",
               "status" => 400,
               "title" => "Bad Request",
               "detail" => "Batch size exceeds maximum of 10000"
             } = json_response(conn, 400)
    end

    test "returns 400 when flow_logs key is missing", %{conn: conn, account: account} do
      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"something" => "else"})

      assert %{
               "type" => "about:blank",
               "status" => 400,
               "title" => "Bad Request",
               "detail" => "Expected a \"flow_logs\" array"
             } = json_response(conn, 400)
    end

    test "returns 400 when flow_logs is not a list", %{conn: conn, account: account} do
      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => "not a list"})

      assert %{
               "type" => "about:blank",
               "status" => 400,
               "title" => "Bad Request"
             } = json_response(conn, 400)
    end

    test "returns 202 with gateway token", %{conn: conn, account: account} do
      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [build_flow_record()]})

      assert %{"data" => %{"status" => "accepted"}} = json_response(conn, 202)
    end

    test "returns 202 with client token", %{conn: conn, account: account} do
      conn =
        conn
        |> authorize_client(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [build_flow_record()]})

      assert %{"data" => %{"status" => "accepted"}} = json_response(conn, 202)
    end

    test "batch of records persisted", %{conn: conn, account: account} do
      records = for _ <- 1..3, do: build_flow_record()

      conn
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => records})

      logs = Repo.all(FlowLog)
      assert length(logs) == 3
      assert Enum.all?(logs, &(&1.account_id == account.id))
    end

    test "reposting the same flow is idempotent", %{conn: conn, account: account} do
      record = build_flow_record()

      conn
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      build_conn()
      |> put_req_header("user-agent", "testing")
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert length(Repo.all(FlowLog)) == 1
    end

    test "an overlapping report of the same flow is dropped", %{conn: conn, account: account} do
      record = build_flow_record()

      overlapping =
        Map.merge(record, %{
          "flow_start" => "2026-03-20T10:03:00.000000Z",
          "flow_end" => "2026-03-20T10:08:00.000000Z",
          "last_packet" => "2026-03-20T10:07:58.000000Z"
        })

      conn
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      build_conn()
      |> put_req_header("user-agent", "testing")
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [overlapping]})

      assert [log] = Repo.all(FlowLog)
      assert log.flow_start == ~U[2026-03-20 10:00:00.000000Z]
    end

    test "a split flow starting exactly at the prior flow_end is kept", %{
      conn: conn,
      account: account
    } do
      record = build_flow_record()

      continuation =
        Map.merge(record, %{
          "flow_start" => record["flow_end"],
          "flow_end" => "2026-03-20T10:09:00.000000Z",
          "last_packet" => "2026-03-20T10:08:58.000000Z"
        })

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record, continuation]})

      assert json_response(conn, 202)
      assert length(Repo.all(FlowLog)) == 2
    end

    test "an intra-batch duplicate flow is dropped without failing the batch", %{
      conn: conn,
      account: account
    } do
      record = build_flow_record()

      overlapping =
        Map.merge(record, %{
          "flow_start" => "2026-03-20T10:03:00.000000Z",
          "flow_end" => "2026-03-20T10:08:00.000000Z"
        })

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record, overlapping]})

      assert json_response(conn, 202)
      assert length(Repo.all(FlowLog)) == 1
    end

    test "persists the flow accounting fields", %{conn: conn, account: account} do
      record = build_flow_record(%{"protocol" => "udp"})

      conn
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      [log] = Repo.all(FlowLog)
      assert log.role == "responder"
      assert log.protocol == "udp"
      assert log.last_packet == ~U[2026-03-20 10:04:58.000000Z]
      assert log.device_id == record["device_id"]
      assert log.actor_id == record["actor_id"]
      assert log.actor_name == "Test User"
      assert log.actor_email == "user@example.com"
      assert log.auth_provider_id == record["auth_provider_id"]
      assert log.resource_id == record["resource_id"]
      assert log.resource_name == "GitLab"
      assert log.resource_address == "gitlab.company.com"
      assert "#{log.inner_src_ip}" == "100.64.0.1"
      assert "#{log.inner_dst_ip}" == "10.0.0.5"
      assert log.inner_src_port == 54_321
      assert log.inner_dst_port == 443
      assert log.inner_domain == "gitlab.company.com"
      assert "#{log.outer_src_ip}" == "203.0.113.10"
      assert "#{log.outer_dst_ip}" == "198.51.100.5"
      assert log.outer_src_port == 51_820
      assert log.outer_dst_port == 51_820
      assert log.rx_packets == 100
      assert log.tx_packets == 80
      assert log.rx_bytes == 102_400
      assert log.tx_bytes == 20_480
    end

    test "ignores unknown fields", %{conn: conn, account: account} do
      record = build_flow_record(%{"some_future_field" => "value"})

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert json_response(conn, 202)
      assert length(Repo.all(FlowLog)) == 1
    end

    test "returns 422 with invalid protocol", %{conn: conn, account: account} do
      record = build_flow_record(%{"protocol" => "icmp"})

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => errors
             } = json_response(conn, 422)

      assert Map.has_key?(errors, "0")
    end

    test "returns 422 when a required accounting field is missing", %{
      conn: conn,
      account: account
    } do
      record = build_flow_record() |> Map.delete("resource_id")

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => errors
             } = json_response(conn, 422)

      assert Map.has_key?(errors, "0")
    end

    test "a gateway's role is forced to responder regardless of the payload", %{
      conn: conn,
      account: account
    } do
      record = build_flow_record(%{"role" => "initiator"})

      conn
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert [log] = Repo.all(FlowLog)
      assert log.role == "responder"
    end

    test "a client reports its own role", %{conn: conn, account: account} do
      record = build_flow_record(%{"role" => "responder"})

      conn
      |> authorize_client(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert [log] = Repo.all(FlowLog)
      assert log.role == "responder"
    end

    test "returns 422 when a client supplies an invalid role", %{conn: conn, account: account} do
      record = build_flow_record(%{"role" => "sideways"})

      conn =
        conn
        |> authorize_client(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => errors
             } = json_response(conn, 422)

      assert Map.has_key?(errors, "0")
    end

    test "the same flow reported by both sides creates two rows", %{
      conn: conn,
      account: account
    } do
      record = build_flow_record(%{"role" => "initiator"})
      other_side = Map.put(record, "device_id", Ecto.UUID.generate())

      conn
      |> authorize_client(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      build_conn()
      |> put_req_header("user-agent", "testing")
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [other_side]})

      logs = Repo.all(FlowLog)
      assert Enum.sort(Enum.map(logs, & &1.role)) == ["initiator", "responder"]
    end

    test "returns 422 with invalid UUID for device_id", %{
      conn: conn,
      account: account
    } do
      record = build_flow_record(%{"device_id" => "not-a-uuid"})

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => errors
             } = json_response(conn, 422)

      assert Map.has_key?(errors, "0")
    end

    test "returns 422 with invalid datetime for flow_start", %{conn: conn, account: account} do
      record = build_flow_record(%{"flow_start" => "not-a-datetime"})

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => errors
             } = json_response(conn, 422)

      assert Map.has_key?(errors, "0")
    end

    test "returns 422 when flow_end is before flow_start", %{conn: conn, account: account} do
      record =
        build_flow_record(%{
          "flow_start" => "2026-03-20T10:05:00.000000Z",
          "flow_end" => "2026-03-20T10:00:00.000000Z"
        })

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => errors
             } = json_response(conn, 422)

      assert Map.has_key?(errors, "0")
    end

    test "returns 422 when record is not a JSON object", %{conn: conn, account: account} do
      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => ["not a map", 42, nil]})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => errors
             } = json_response(conn, 422)

      assert errors["0"]["record"] == ["must be a JSON object"]
      assert errors["1"]["record"] == ["must be a JSON object"]
      assert errors["2"]["record"] == ["must be a JSON object"]
    end

    test "partial batch inserts valid records and returns 422 with errors", %{
      conn: conn,
      account: account
    } do
      good_record = build_flow_record()
      bad_record = build_flow_record(%{"flow_start" => "invalid"})

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [good_record, bad_record]})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "validation_errors" => errors
             } = json_response(conn, 422)

      assert Map.has_key?(errors, "1")
      assert length(Repo.all(FlowLog)) == 1
    end
  end
end
