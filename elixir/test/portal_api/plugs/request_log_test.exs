defmodule PortalAPI.Plugs.RequestLogTest do
  use PortalAPI.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SubjectFixtures

  alias Portal.APIRequestLog
  alias Portal.Repo
  alias PortalAPI.Plugs.RequestLog

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "through the :api pipeline" do
    test "records one api_request_log per authenticated request", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/account")

      assert json_response(conn, 200)

      assert [log] = Repo.all(APIRequestLog)
      assert log.account_id == account.id
      assert log.actor_id == actor.id

      api_token = Repo.one(from t in Portal.APIToken, where: t.actor_id == ^actor.id)
      assert log.api_token_id == api_token.id

      assert String.starts_with?(log.event_id, "a")
      assert log.method == "GET"
      assert log.path == "/account"
      assert log.content_length == nil
      assert is_binary(log.request_id)
      assert log.remote_ip == %Postgrex.INET{address: {127, 0, 0, 1}}

      # inserted_at is filled by the database default
      assert log.inserted_at
      assert DateTime.diff(DateTime.utc_now(), log.inserted_at, :second) < 60
    end

    test "records a row per request", %{actor: actor} do
      for _ <- 1..2 do
        conn =
          build_conn()
          |> authorize_conn(actor)
          |> put_req_header("content-type", "application/json")
          |> get(~p"/account")

        assert json_response(conn, 200)
      end

      assert Repo.aggregate(APIRequestLog, :count) == 2
    end

    test "records the RemoteIp-resolved client address, not the peer", %{actor: actor} do
      conn =
        build_conn()
        |> authorize_conn(actor)
        |> put_req_header("x-forwarded-for", "203.0.113.5")
        |> put_req_header("content-type", "application/json")
        |> get(~p"/account")

      assert json_response(conn, 200)

      assert [log] = Repo.all(APIRequestLog)
      assert log.remote_ip == %Postgrex.INET{address: {203, 0, 113, 5}}
    end

    test "does not record unauthenticated requests", %{conn: conn} do
      conn = get(conn, ~p"/account")

      assert json_response(conn, 401)
      assert Repo.aggregate(APIRequestLog, :count) == 0
    end
  end

  describe "call/2" do
    test "captures the subject context fields", %{account: account} do
      subject =
        subject_fixture(
          account: account,
          actor: [type: :api_client],
          user_agent: "testclient/2.0"
        )

      conn =
        build_conn()
        |> with_request_id()
        |> Plug.Conn.assign(:subject, subject)
        |> RequestLog.call([])

      refute conn.halted

      assert [log] = Repo.all(APIRequestLog)
      assert log.user_agent == "testclient/2.0"
      assert log.remote_ip == %Postgrex.INET{address: {100, 64, 0, 1}}
      assert log.remote_ip_location_region == "US"
      assert log.remote_ip_location_city == "San Francisco"
      assert log.remote_ip_location_lat == 37.7749
      assert log.remote_ip_location_lon == -122.4194
      assert log.api_token_id == subject.credential.id
    end

    test "truncates oversized context fields instead of failing", %{account: account} do
      subject =
        subject_fixture(
          account: account,
          actor: [type: :api_client],
          user_agent: String.duplicate("a", 300)
        )

      log =
        capture_log(fn ->
          build_conn()
          |> with_request_id()
          |> Plug.Conn.assign(:subject, subject)
          |> RequestLog.call([])
        end)

      assert log =~ "Truncated session field"

      assert [api_request_log] = Repo.all(APIRequestLog)
      assert String.length(api_request_log.user_agent) == 255
    end

    test "captures method, path, and content_length", %{account: account} do
      subject = subject_fixture(account: account, actor: [type: :api_client])

      build_conn(:post, "/policies")
      |> with_request_id()
      |> Plug.Conn.put_req_header("content-length", "42")
      |> Plug.Conn.assign(:subject, subject)
      |> RequestLog.call([])

      assert [log] = Repo.all(APIRequestLog)
      assert log.method == "POST"
      assert log.path == "/policies"
      assert log.content_length == 42
    end

    test "records a malformed content-length header as nil", %{account: account} do
      subject = subject_fixture(account: account, actor: [type: :api_client])

      build_conn(:post, "/policies")
      |> with_request_id()
      |> Plug.Conn.put_req_header("content-length", "not-a-number")
      |> Plug.Conn.assign(:subject, subject)
      |> RequestLog.call([])

      assert [log] = Repo.all(APIRequestLog)
      assert log.content_length == nil
    end

    test "raises when the insert fails so the request cannot proceed unlogged", %{
      account: account
    } do
      subject = subject_fixture(account: account, actor: [type: :api_client])

      # Point the subject at an account that does not exist so the account
      # assoc constraint rejects the insert.
      subject = %{subject | account: %{subject.account | id: Ecto.UUID.generate()}}

      assert_raise MatchError, fn ->
        build_conn()
        |> with_request_id()
        |> Plug.Conn.assign(:subject, subject)
        |> RequestLog.call([])
      end

      assert Repo.aggregate(APIRequestLog, :count) == 0
    end
  end

  # Plug.RequestId runs in the endpoint, so direct plug calls have to set the
  # header themselves.
  defp with_request_id(conn) do
    Plug.Conn.put_resp_header(conn, "x-request-id", "F8nMlbf6MUyJZUUABBzB9-yT")
  end
end
