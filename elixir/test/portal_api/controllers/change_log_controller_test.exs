defmodule PortalAPI.ChangeLogControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ChangeLogFixtures

  alias Portal.Types.EventId

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, ~p"/change_logs")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "returns unauthorized for an actor without permission", %{conn: conn, account: account} do
      unprivileged = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unprivileged)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "lists change logs scoped to the account", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      change_logs =
        for _ <- 1..3,
            do: change_log_fixture(account: account)

      other_account = account_fixture()
      _other = change_log_fixture(account: other_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert count == 3
      assert limit == 50
      assert is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["event_id"])
      change_log_ids = Enum.map(change_logs, & &1.event_id)
      assert MapSet.equal?(MapSet.new(data_ids), MapSet.new(change_log_ids))
    end

    test "orders most recent first", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      base = DateTime.utc_now()

      cl_older = change_log_fixture(account: account, timestamp: DateTime.add(base, -60, :second))
      cl_mid = change_log_fixture(account: account, timestamp: DateTime.add(base, -30, :second))
      cl_newest = change_log_fixture(account: account, timestamp: base)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs")

      assert %{"data" => data} = json_response(conn, 200)
      ids = Enum.map(data, & &1["event_id"])

      assert ids == [cl_newest.event_id, cl_mid.event_id, cl_older.event_id]
    end

    test "filters by begin (inclusive lower bound)", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      now = DateTime.utc_now()

      _too_old =
        change_log_fixture(account: account, timestamp: DateTime.add(now, -120, :second))

      keeper =
        change_log_fixture(account: account, timestamp: DateTime.add(now, -60, :second))

      begin_at = DateTime.add(now, -90, :second)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", begin: DateTime.to_iso8601(begin_at))

      assert %{"data" => data, "metadata" => %{"count" => count}} = json_response(conn, 200)
      assert count == 1
      assert [%{"event_id" => event_id}] = data
      assert event_id == keeper.event_id
    end

    test "filters by end (inclusive upper bound)", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      now = DateTime.utc_now()

      keeper =
        change_log_fixture(account: account, timestamp: DateTime.add(now, -120, :second))

      _too_new =
        change_log_fixture(account: account, timestamp: DateTime.add(now, -10, :second))

      end_at = DateTime.add(now, -60, :second)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", end: DateTime.to_iso8601(end_at))

      assert %{"data" => [%{"event_id" => event_id}], "metadata" => %{"count" => 1}} =
               json_response(conn, 200)

      assert event_id == keeper.event_id
    end

    test "begin and end are inclusive on the boundary", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      ts = ~U[2026-05-01 12:00:00.000000Z]

      keeper = change_log_fixture(account: account, timestamp: ts)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs",
          begin: DateTime.to_iso8601(ts),
          end: DateTime.to_iso8601(ts)
        )

      assert %{"data" => [%{"event_id" => event_id}]} = json_response(conn, 200)
      assert event_id == keeper.event_id
    end

    test "defaults exclude entries older than 90 days", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      now = DateTime.utc_now()

      _too_old =
        change_log_fixture(
          account: account,
          timestamp: DateTime.add(now, -91 * 24 * 60 * 60, :second)
        )

      keeper =
        change_log_fixture(
          account: account,
          timestamp: DateTime.add(now, -3600, :second)
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs")

      assert %{"data" => [%{"event_id" => event_id}], "metadata" => %{"count" => 1}} =
               json_response(conn, 200)

      assert event_id == keeper.event_id
    end

    test "filters by actor_id on subject", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      target_actor_id = "84e7f82f-831a-4a9d-8f17-c66c2bb6e205"
      other_actor_id = "00000000-0000-0000-0000-000000000001"

      keeper =
        change_log_fixture(
          account: account,
          subject: %{"actor_id" => target_actor_id, "actor_email" => "x@example.com"}
        )

      _miss =
        change_log_fixture(
          account: account,
          subject: %{"actor_id" => other_actor_id, "actor_email" => "y@example.com"}
        )

      _no_subject = change_log_fixture(account: account, subject: nil)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", actor_id: target_actor_id)

      assert %{"data" => [%{"event_id" => event_id}], "metadata" => %{"count" => 1}} =
               json_response(conn, 200)

      assert event_id == keeper.event_id
    end

    test "filters by actor_email on subject", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      keeper =
        change_log_fixture(
          account: account,
          subject: %{
            "actor_id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "actor_email" => "admin@example.com"
          }
        )

      _miss =
        change_log_fixture(
          account: account,
          subject: %{
            "actor_id" => "00000000-0000-0000-0000-000000000001",
            "actor_email" => "other@example.com"
          }
        )

      _no_subject = change_log_fixture(account: account, subject: nil)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", actor_email: "admin@example.com")

      assert %{"data" => [%{"event_id" => event_id}], "metadata" => %{"count" => 1}} =
               json_response(conn, 200)

      assert event_id == keeper.event_id
    end

    test "actor_id and actor_email filters combine", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      actor_id = "84e7f82f-831a-4a9d-8f17-c66c2bb6e205"

      keeper =
        change_log_fixture(
          account: account,
          subject: %{"actor_id" => actor_id, "actor_email" => "admin@example.com"}
        )

      _wrong_email =
        change_log_fixture(
          account: account,
          subject: %{"actor_id" => actor_id, "actor_email" => "other@example.com"}
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", actor_id: actor_id, actor_email: "admin@example.com")

      assert %{"data" => [%{"event_id" => event_id}], "metadata" => %{"count" => 1}} =
               json_response(conn, 200)

      assert event_id == keeper.event_id
    end

    test "returns 400 when begin is not a valid RFC 3339 timestamp", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", begin: "not-a-date")

      assert %{"detail" => reason} = json_response(conn, 400)
      assert reason =~ "`begin`"
      assert reason =~ "RFC 3339"
    end

    test "returns 400 when end is not a valid RFC 3339 timestamp", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", end: "2026-13-99")

      assert %{"detail" => reason} = json_response(conn, 400)
      assert reason =~ "`end`"
    end

    test "returns 400 when begin is after end", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs",
          begin: "2026-05-26T00:00:00Z",
          end: "2026-05-25T00:00:00Z"
        )

      assert %{"detail" => reason} = json_response(conn, 400)
      assert reason =~ "`begin`"
      assert reason =~ "`end`"
    end

    test "returns 400 when actor_id is not a UUID", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", actor_id: "not-a-uuid")

      assert %{"detail" => reason} = json_response(conn, 400)
      assert reason =~ "`actor_id`"
    end

    test "accepts empty begin and end as defaults", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      _keeper = change_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", begin: "", end: "")

      assert %{"metadata" => %{"count" => 1}} = json_response(conn, 200)
    end

    test "accepts empty actor_id and actor_email as no filter", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      _keeper =
        change_log_fixture(
          account: account,
          subject: %{
            "actor_id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "actor_email" => "admin@example.com"
          }
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", actor_id: "", actor_email: "")

      assert %{"metadata" => %{"count" => 1}} = json_response(conn, 200)
    end

    test "returns 400 when begin is not a string", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", begin: %{"x" => "1"})

      assert %{"detail" => reason} = json_response(conn, 400)
      assert reason =~ "`begin`"
      assert reason =~ "must be a string"
    end

    test "returns 400 when actor_id is not a string", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", actor_id: %{"x" => "1"})

      assert %{"detail" => reason} = json_response(conn, 400)
      assert reason =~ "`actor_id`"
      assert reason =~ "must be a string"
    end

    test "returns 400 when actor_email is not a string", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", actor_email: %{"x" => "1"})

      assert %{"detail" => reason} = json_response(conn, 400)
      assert reason =~ "`actor_email`"
      assert reason =~ "must be a string"
    end

    test "renders subject as null when the entry has no subject", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      _change_log = change_log_fixture(account: account, subject: nil)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs")

      assert %{"data" => [entry]} = json_response(conn, 200)
      assert Map.has_key?(entry, "subject")
      assert entry["subject"] == nil
    end

    test "supports pagination with limit and cursor", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      base = DateTime.utc_now()

      change_logs =
        for offset <- 0..4 do
          change_log_fixture(
            account: account,
            timestamp: DateTime.add(base, -offset, :second)
          )
        end

      conn1 =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", limit: "2")

      assert %{
               "data" => page1,
               "metadata" => %{"count" => 5, "limit" => 2, "next_page" => next, "prev_page" => nil}
             } = json_response(conn1, 200)

      assert length(page1) == 2
      refute is_nil(next)

      conn2 =
        build_conn()
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs", limit: "2", page_cursor: next)

      assert %{"data" => page2, "metadata" => %{"prev_page" => prev2}} = json_response(conn2, 200)
      assert length(page2) == 2
      refute is_nil(prev2)

      seen = Enum.map(page1 ++ page2, & &1["event_id"])

      all_ids = Enum.map(change_logs, & &1.event_id)
      assert MapSet.subset?(MapSet.new(seen), MapSet.new(all_ids))

      newest_four =
        change_logs
        |> Enum.sort_by(& &1.event_id, :desc)
        |> Enum.take(4)
        |> Enum.map(& &1.event_id)

      assert hd(seen) in newest_four
    end

    test "does not expose internal fields", %{conn: conn, actor: actor, account: account} do
      _change_log = change_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs")

      assert %{"data" => [entry]} = json_response(conn, 200)
      refute Map.has_key?(entry, "lsn")
      refute Map.has_key?(entry, "vsn")
      refute Map.has_key?(entry, "table")
    end

    test "renders all documented fields", %{conn: conn, actor: actor, account: account} do
      timestamp = ~U[2026-05-01 12:00:00.000000Z]

      change_log =
        change_log_fixture(
          account: account,
          operation: :update,
          object: "actors",
          before: %{"name" => "Before"},
          after: %{"name" => "After"},
          subject: %{
            "actor_id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "actor_name" => "Admin",
            "actor_email" => "admin@example.com",
            "actor_type" => "account_admin_user",
            "auth_provider_id" => "98776234-1234-5678-9012-345678901234",
            "ip" => "1.2.3.4"
          },
          timestamp: timestamp
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs")

      assert %{"data" => [entry]} = json_response(conn, 200)

      assert entry == %{
               "event_id" => change_log.event_id,
               "timestamp" => DateTime.to_iso8601(change_log.timestamp),
               "object" => "actors",
               "operation" => "update",
               "before" => %{"name" => "Before"},
               "after" => %{"name" => "After"},
               "subject" => %{
                 "actor_id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
                 "actor_name" => "Admin",
                 "actor_email" => "admin@example.com",
                 "actor_type" => "account_admin_user",
                 "auth_provider_id" => "98776234-1234-5678-9012-345678901234",
                 "ip" => "1.2.3.4"
               }
             }
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      change_log = change_log_fixture(account: account)
      conn = get(conn, ~p"/change_logs/#{change_log.event_id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "returns unauthorized for an actor without permission", %{conn: conn, account: account} do
      change_log = change_log_fixture(account: account)
      unprivileged = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unprivileged)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs/#{change_log.event_id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "returns 400 when event_id is not a 24-char hex string", %{conn: conn, actor: actor} do
      # A UUID passes the ValidateUUIDParams plug but is not a 24-char hex EventId,
      # so it reaches the controller's parse_event_id/1 error branch.
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/change_logs/#{Ecto.UUID.generate()}")

      assert %{"detail" => reason} = json_response(conn, 400)
      assert reason =~ "`event_id`"
    end

    test "returns a single change log", %{conn: conn, actor: actor, account: account} do
      change_log = change_log_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs/#{change_log.event_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["event_id"] == change_log.event_id
      assert data["object"] == change_log.object
      assert data["operation"] == Atom.to_string(change_log.operation)
      refute Map.has_key?(data, "lsn")
      refute Map.has_key?(data, "vsn")
      refute Map.has_key?(data, "table")
    end

    test "returns 404 for non-existent event_id", %{conn: conn, actor: actor} do
      missing_id = EventId.build_change_log(1, 0)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs/#{missing_id}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} = json_response(conn, 404)
    end

    test "returns 400 when event_id is not a valid identifier", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs/not-a-uuid")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} = json_response(conn, 400)
    end

    test "returns 404 when the change log belongs to a different account", %{
      conn: conn,
      actor: actor
    } do
      other_account = account_fixture()
      change_log = change_log_fixture(account: other_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/change_logs/#{change_log.event_id}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} = json_response(conn, 404)
    end
  end
end
