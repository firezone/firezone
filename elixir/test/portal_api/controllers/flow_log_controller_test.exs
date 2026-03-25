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
      "flow_id" => Ecto.UUID.generate(),
      "device_id" => Ecto.UUID.generate(),
      "role" => "initiator",
      "flow_start" => "2026-03-20T10:00:00.000000Z",
      "flow_end" => "2026-03-20T10:05:00.000000Z",
      "bytes_sent" => 1024,
      "protocol" => "tcp"
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

    test "duplicate flow_id + device_id is idempotent", %{conn: conn, account: account} do
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

    test "payload captures extra fields", %{conn: conn, account: account} do
      record =
        build_flow_record(%{
          "bytes_sent" => 2048,
          "bytes_received" => 512,
          "protocol" => "udp",
          "destination" => "10.0.0.1:443"
        })

      conn
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      [log] = Repo.all(FlowLog)
      assert log.payload["bytes_sent"] == 2048
      assert log.payload["bytes_received"] == 512
      assert log.payload["protocol"] == "udp"
      assert log.payload["destination"] == "10.0.0.1:443"
    end

    test "returns 422 with invalid role", %{conn: conn, account: account} do
      record = build_flow_record(%{"role" => "sideways"})

      conn =
        conn
        |> authorize_gateway(account)
        |> post("/ingestion/flow_logs", %{"flow_logs" => [record]})

      assert %{
               "type" => "about:blank",
               "status" => 422,
               "title" => "Unprocessable Content",
               "validation_errors" => errors
             } = json_response(conn, 422)

      assert Map.has_key?(errors, "0")
    end

    test "returns 422 with invalid UUID for device_id", %{conn: conn, account: account} do
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

    test "same flow_id with initiator and responder creates two rows", %{
      conn: conn,
      account: account
    } do
      flow_id = Ecto.UUID.generate()

      initiator_record =
        build_flow_record(%{
          "flow_id" => flow_id,
          "device_id" => Ecto.UUID.generate(),
          "role" => "initiator"
        })

      responder_record =
        build_flow_record(%{
          "flow_id" => flow_id,
          "device_id" => Ecto.UUID.generate(),
          "role" => "responder"
        })

      conn
      |> authorize_gateway(account)
      |> post("/ingestion/flow_logs", %{
        "flow_logs" => [initiator_record, responder_record]
      })

      logs = Repo.all(FlowLog)
      assert length(logs) == 2
      assert Enum.all?(logs, &(&1.flow_id == flow_id))
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
