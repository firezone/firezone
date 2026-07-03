defmodule PortalAPI.LogControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.APIRequestLogFixtures
  import Portal.ChangeLogFixtures
  import Portal.FlowLogFixtures
  import Portal.SessionLogFixtures
  import Portal.SubjectFixtures

  alias PortalAPI.LogController

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "index/2 auth" do
    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, ~p"/logs?type=change")
      assert json_response(conn, 401)
    end
  end

  describe "index/2 type validation" do
    test "returns 400 when type is missing", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`type` is required"
    end

    test "returns 400 for an unknown type", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=bogus")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`type` must be one of"
    end
  end

  describe "index/2 type=change" do
    test "lists change logs most recent first", %{conn: conn, account: account, actor: actor} do
      logs = for _ <- 1..3, do: change_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change")

      assert %{"data" => data} = json_response(conn, 200)
      assert length(data) == 3
      assert Enum.all?(data, &(&1["type"] == "change"))

      expected = logs |> Enum.map(& &1.event_id) |> Enum.sort(:desc)
      assert Enum.map(data, & &1["event_id"]) == expected
    end

    test "renders change log fields", %{conn: conn, account: account, actor: actor} do
      change_log =
        change_log_fixture(
          account: account,
          object: "actors",
          operation: :update,
          before: %{"name" => "Jane Doe"},
          after: %{"name" => "Jane Smith"},
          subject: %{"actor_id" => Ecto.UUID.generate()}
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["event_id"] == change_log.event_id
      assert data["object"] == "actors"
      assert data["operation"] == "update"
      assert data["before"] == %{"name" => "Jane Doe"}
      assert data["after"] == %{"name" => "Jane Smith"}
      assert data["subject"] == change_log.subject
    end

    test "does not return another account's change logs", %{conn: conn, actor: actor} do
      change_log_fixture()

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "filters by actor_id and actor_email on the subject", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      actor_id = Ecto.UUID.generate()

      matching =
        change_log_fixture(
          account: account,
          subject: %{"actor_id" => actor_id, "actor_email" => "admin@example.com"}
        )

      change_log_fixture(
        account: account,
        subject: %{"actor_id" => Ecto.UUID.generate(), "actor_email" => "other@example.com"}
      )

      conn1 =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&actor_id=#{actor_id}")

      assert %{"data" => [%{"event_id" => event_id}]} = json_response(conn1, 200)
      assert event_id == matching.event_id

      conn2 =
        build_conn()
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&actor_email=admin@example.com")

      assert %{"data" => [%{"event_id" => event_id}]} = json_response(conn2, 200)
      assert event_id == matching.event_id
    end

    test "bounds the window with begin and end", %{conn: conn, account: account, actor: actor} do
      old = change_log_fixture(account: account, timestamp: ~U[2026-01-01 00:00:00.000000Z])
      change_log_fixture(account: account, timestamp: ~U[2026-03-01 00:00:00.000000Z])

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&begin=2025-12-01T00:00:00Z&end=2026-02-01T00:00:00Z")

      assert %{"data" => [%{"event_id" => event_id}]} = json_response(conn, 200)
      assert event_id == old.event_id
    end

    test "paginates with limit and page_cursor", %{conn: conn, account: account, actor: actor} do
      for _ <- 1..3, do: change_log_fixture(account: account)

      conn1 =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&limit=2")

      assert %{"data" => page1, "metadata" => %{"next_page" => cursor}} =
               json_response(conn1, 200)

      assert length(page1) == 2
      assert cursor

      conn2 =
        build_conn()
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&limit=2&page_cursor=#{cursor}")

      assert %{"data" => page2} = json_response(conn2, 200)
      assert length(page2) == 1
      assert MapSet.disjoint?(
               MapSet.new(page1, & &1["event_id"]),
               MapSet.new(page2, & &1["event_id"])
             )
    end

    test "returns 400 for an invalid page_cursor", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&page_cursor=bogus")

      assert json_response(conn, 400)
    end
  end

  describe "index/2 type=session" do
    test "lists session logs most recent first", %{conn: conn, account: account, actor: actor} do
      oldest = session_log_fixture(account: account, timestamp: ~U[2026-06-01 00:00:00.000000Z])
      middle = session_log_fixture(account: account, timestamp: ~U[2026-06-02 00:00:00.000000Z])
      newest = session_log_fixture(account: account, timestamp: ~U[2026-06-03 00:00:00.000000Z])

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=session")

      assert %{"data" => data} = json_response(conn, 200)

      assert Enum.map(data, & &1["event_id"]) ==
               [newest.event_id, middle.event_id, oldest.event_id]

      assert Enum.all?(data, &(&1["type"] == "session"))
    end

    test "renders session log fields", %{conn: conn, account: account, actor: actor} do
      session_log =
        session_log_fixture(
          account: account,
          context: :portal,
          actor_email: "admin@example.com"
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=session")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["event_id"] == session_log.event_id
      assert data["context"] == "portal"

      assert data["subject"] == session_log.subject
      assert data["subject"]["actor_email"] == "admin@example.com"
      assert data["subject"]["device_id"] == session_log.subject["device_id"]
      assert data["subject"]["token_id"] == session_log.subject["token_id"]
      assert data["subject"]["user_agent"] == "testclient/1.0"
      assert data["subject"]["ip"] == "189.172.73.1"
      assert data["subject"]["ip_region"] == "US"
      assert data["subject"]["ip_city"] == "San Francisco"
      assert data["subject"]["ip_lat"] == 37.7749
      assert data["subject"]["ip_lon"] == -122.4194
    end

    test "filters by actor_id", %{conn: conn, account: account, actor: actor} do
      actor_id = Ecto.UUID.generate()
      matching = session_log_fixture(account: account, context: :portal, actor_id: actor_id)
      session_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=session&actor_id=#{actor_id}")

      assert %{"data" => [%{"event_id" => event_id}]} = json_response(conn, 200)
      assert event_id == matching.event_id
    end

    test "filters by actor_email recorded on the session", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      matching =
        session_log_fixture(
          account: account,
          context: :portal,
          actor_email: "target@example.com"
        )

      session_log_fixture(account: account, actor_email: "other@example.com")

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=session&actor_email=target@example.com")

      assert %{"data" => [%{"event_id" => event_id}]} = json_response(conn, 200)
      assert event_id == matching.event_id
    end

    test "does not return another account's session logs", %{conn: conn, actor: actor} do
      session_log_fixture()

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=session")

      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "index/2 type=flow" do
    test "lists flow logs most recently started first", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      older =
        flow_log_fixture(
          account: account,
          flow_start: ~U[2026-06-01 00:00:00.000000Z],
          flow_end: ~U[2026-06-01 00:01:00.000000Z]
        )

      newer =
        flow_log_fixture(
          account: account,
          flow_start: ~U[2026-06-02 00:00:00.000000Z],
          flow_end: ~U[2026-06-02 00:01:00.000000Z]
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=flow")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.map(data, & &1["event_id"]) == [newer.event_id, older.event_id]
      assert Enum.all?(data, &(&1["type"] == "flow"))
    end

    test "the window matches flows active inside it, not their ingestion time", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      # Spans the whole window despite starting before it.
      long_lived =
        flow_log_fixture(
          account: account,
          flow_start: ~U[2026-06-01 00:00:00.000000Z],
          flow_end: ~U[2026-06-05 00:00:00.000000Z]
        )

      # Active inside the window, but ingested long after it.
      late_report =
        flow_log_fixture(
          account: account,
          flow_start: ~U[2026-06-03 11:00:00.000000Z],
          flow_end: ~U[2026-06-03 13:00:00.000000Z],
          inserted_at: ~U[2026-06-08 00:00:00.000000Z]
        )

      # Ended before the window began.
      flow_log_fixture(
        account: account,
        flow_start: ~U[2026-06-02 00:00:00.000000Z],
        flow_end: ~U[2026-06-03 00:00:00.000000Z]
      )

      # Started after the window ended.
      flow_log_fixture(
        account: account,
        flow_start: ~U[2026-06-04 00:00:00.000000Z],
        flow_end: ~U[2026-06-04 01:00:00.000000Z]
      )

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=flow&begin=2026-06-03T10:00:00Z&end=2026-06-03T14:00:00Z")

      assert %{"data" => data} = json_response(conn, 200)

      assert Enum.map(data, & &1["event_id"]) == [late_report.event_id, long_lived.event_id]
    end

    test "renders flow log fields", %{conn: conn, account: account, actor: actor} do
      flow_log = flow_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=flow")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["event_id"] == flow_log.event_id
      assert data["device_id"] == flow_log.device_id
      assert data["role"] == "responder"
      assert data["protocol"] == "tcp"
      assert data["actor_id"] == flow_log.actor_id
      assert data["actor_email"] == "user@example.com"
      assert data["resource_id"] == flow_log.resource_id
      assert data["resource_name"] == "GitLab"
      assert data["resource_address"] == "gitlab.company.com"
      assert data["inner_src_ip"] == "100.64.0.1"
      assert data["inner_dst_ip"] == "10.0.0.5"
      assert data["inner_src_port"] == 54_321
      assert data["inner_dst_port"] == 443
      assert data["outer_src_ip"] == "203.0.113.10"
      assert data["outer_dst_ip"] == "198.51.100.5"
      assert data["rx_packets"] == 100
      assert data["tx_packets"] == 80
      assert data["rx_bytes"] == 102_400
      assert data["tx_bytes"] == 20_480
    end

    test "filters by actor_id", %{conn: conn, account: account, actor: actor} do
      actor_id = Ecto.UUID.generate()
      matching = flow_log_fixture(account: account, actor_id: actor_id)
      flow_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=flow&actor_id=#{actor_id}")

      assert %{"data" => [%{"event_id" => event_id}]} = json_response(conn, 200)
      assert event_id == matching.event_id
    end

    test "filters by actor_email via the email recorded on the flow", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      matching = flow_log_fixture(account: account, actor_email: "target@example.com")
      flow_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=flow&actor_email=target@example.com")

      assert %{"data" => [%{"event_id" => event_id}]} = json_response(conn, 200)
      assert event_id == matching.event_id
    end
  end

  describe "index/2 type=api_request" do
    test "lists api request logs including the listing request itself", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      log1 = api_request_log_fixture(account: account)
      log2 = api_request_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=api_request")

      assert %{"data" => data} = json_response(conn, 200)

      # The RequestLog plug records this request before the controller runs,
      # so the listing includes its own entry.
      assert length(data) == 3
      assert Enum.all?(data, &(&1["type"] == "api_request"))

      event_ids = MapSet.new(data, & &1["event_id"])
      assert MapSet.member?(event_ids, log1.event_id)
      assert MapSet.member?(event_ids, log2.event_id)
    end

    test "filters by actor_id", %{conn: conn, account: account, actor: actor} do
      actor_id = Ecto.UUID.generate()
      matching = api_request_log_fixture(account: account, actor_id: actor_id)
      api_request_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=api_request&actor_id=#{actor_id}")

      assert %{"data" => [%{"event_id" => event_id}]} = json_response(conn, 200)
      assert event_id == matching.event_id
    end

    test "returns 400 when actor_email is combined with type=api_request", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=api_request&actor_email=admin@example.com")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`actor_email` is not supported for `type=api_request`"
    end

    test "renders api request log fields", %{conn: conn, account: account, actor: actor} do
      log =
        api_request_log_fixture(
          account: account,
          method: "POST",
          path: "/policies",
          content_length: 42,
          request_id: "GBKkV1jUWuW2sJoAACkB"
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=api_request&actor_id=#{log.actor_id}")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["event_id"] == log.event_id
      assert data["actor_id"] == log.actor_id
      assert data["api_token_id"] == log.api_token_id
      assert data["method"] == "POST"
      assert data["path"] == "/policies"
      assert data["content_length"] == 42
      assert data["request_id"] == "GBKkV1jUWuW2sJoAACkB"
      assert data["user_agent"] == "testclient/1.0"
      assert data["remote_ip"] == "189.172.73.1"
      assert data["timestamp"]
    end
  end

  describe "index/2 window validation" do
    test "returns 400 when begin is not a timestamp", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&begin=bogus")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`begin` must be an RFC 3339 timestamp"
    end

    test "returns 400 when begin is after end", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&begin=2026-05-01T00:00:00Z&end=2026-04-01T00:00:00Z")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`begin` must be less than or equal to `end`"
    end

    test "returns 400 when actor_id is not a UUID", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&actor_id=bogus")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`actor_id` must be a UUID"
    end

    test "treats empty filter params as absent", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&begin=&end=&actor_id=&actor_email=")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns 400 when begin is not a string", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&begin[]=bogus")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`begin` must be a string"
    end

    test "returns 400 when actor_id is not a string", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&actor_id[]=bogus")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`actor_id` must be a string"
    end

    test "returns 400 when actor_email is not a string", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs?type=change&actor_email[]=bogus")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`actor_email` must be a string"
    end
  end

  describe "show/2" do
    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, ~p"/logs/c00060db0c2c8eb400000000")
      assert json_response(conn, 401)
    end

    test "fetches a change log by its c-prefixed event_id", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      change_log = change_log_fixture(account: account)
      assert String.starts_with?(change_log.event_id, "c")

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/#{change_log.event_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["type"] == "change"
      assert data["event_id"] == change_log.event_id
    end

    test "fetches a session log by its 5-prefixed event_id", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      session_log = session_log_fixture(account: account)
      assert String.starts_with?(session_log.event_id, "5")

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/#{session_log.event_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["type"] == "session"
      assert data["event_id"] == session_log.event_id
      assert data["context"] == "client"
    end

    test "fetches a flow log by its f-prefixed event_id", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      flow_log = flow_log_fixture(account: account)
      assert String.starts_with?(flow_log.event_id, "f")

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/#{flow_log.event_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["type"] == "flow"
      assert data["event_id"] == flow_log.event_id
    end

    test "fetches an api request log by its a-prefixed event_id", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      log = api_request_log_fixture(account: account)
      assert String.starts_with?(log.event_id, "a")

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/#{log.event_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["type"] == "api_request"
      assert data["event_id"] == log.event_id
    end

    test "normalizes uppercase event_ids", %{conn: conn, account: account, actor: actor} do
      change_log = change_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/#{String.upcase(change_log.event_id)}")

      assert %{"data" => %{"event_id" => event_id}} = json_response(conn, 200)
      assert event_id == change_log.event_id
    end

    test "returns 404 for an event_id with an unknown log type nibble", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/100000000000000000000000")

      assert json_response(conn, 404)
    end

    test "returns 404 for a valid event_id that does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/c00000000000000000000000")

      assert json_response(conn, 404)
    end

    test "returns 404 for another account's log", %{conn: conn, actor: actor} do
      other = session_log_fixture()

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/#{other.event_id}")

      assert json_response(conn, 404)
    end

    test "returns 400 for a malformed event_id", %{conn: conn, actor: actor} do
      # ValidateUUIDParams rejects malformed identifiers before the controller.
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/not-hex")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "not valid identifiers"
    end

    test "returns 400 for a UUID-shaped event_id", %{conn: conn, actor: actor} do
      # A UUID passes ValidateUUIDParams but is not a valid event_id.
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/logs/#{Ecto.UUID.generate()}")

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "`event_id` must be a 24-char hex string"
    end
  end

  describe "Database.fetch_log/3" do
    test "passes through unauthorized from the data layer", %{account: account} do
      subject = subject_fixture(account: account, actor: [type: :account_user])

      assert {:error, :unauthorized} =
               LogController.Database.fetch_log(:change, "c00000000000000000000000", subject)
    end
  end
end
