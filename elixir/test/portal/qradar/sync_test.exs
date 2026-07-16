defmodule Portal.QRadar.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.LogSinkFixtures
  import Portal.SessionLogFixtures

  alias Portal.LogSinkCursor
  alias Portal.QRadar

  setup do
    test_pid = self()

    Req.Test.stub(QRadar.APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:receiver, conn, body})

      Plug.Conn.send_resp(conn, 200, "")
    end)

    %{account: account_fixture(features: %{log_sinks: true})}
  end

  describe "perform/1" do
    test "delivers newline-delimited events with the authorization header", %{account: account} do
      sink =
        qradar_log_sink_fixture(
          account: account,
          enabled_streams: [:session],
          auth_header: "Bearer test-shared-secret"
        )

      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})

      refute_receive {:receiver, _conn, _body}

      log = session_log_fixture(account: account)

      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})

      assert_receive {:receiver, conn, body}
      assert conn.method == "POST"
      assert conn.host == URI.parse(sink.endpoint_url).host
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-shared-secret"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/x-ndjson"]

      assert [line] = String.split(body, "\n", trim: true)
      assert String.starts_with?(line, ~s({"type":"session","log_id":"#{log.log_id}"))

      event = JSON.decode!(line)
      assert event["type"] == "session"
      assert event["log_id"] == log.log_id
      assert event["timestamp"]
      assert event["subject"]

      cursor = get_cursor(sink, :session, :live)
      assert cursor.cursor == log.seq
      assert cursor.synced_count == 1
      refute reload_sink(sink).errored_at
    end

    test "batches events one per line, each starting with the message pattern marker", %{
      account: account
    } do
      sink = qradar_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})

      session_log_fixture(account: account)
      session_log_fixture(account: account)

      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})

      assert_receive {:receiver, conn, body}
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      lines = String.split(body, "\n", trim: true)
      assert length(lines) == 2

      for line <- lines do
        assert String.starts_with?(line, ~s({"type":"session","log_id":"))
        assert JSON.decode!(line)["type"] == "session"
      end
    end

    test "a 403 disables the sink immediately with an actionable message", %{account: account} do
      sink = qradar_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(QRadar.APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 403, "Forbidden")
      end)

      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message =~ "IBM QRadar returned HTTP 403"
      assert sink.error_message =~ "authorization header"
    end

    test "a redirect disables the sink and points at the listen port", %{account: account} do
      sink = qradar_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(QRadar.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://qradar.example/console")
        |> Plug.Conn.send_resp(301, "")
      end)

      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message =~ "HTTP 301 redirect"
      assert sink.error_message =~ "listen port"
    end

    test "a 429 is transient", %{account: account} do
      sink = qradar_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(QRadar.APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 429, "")
      end)

      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 0

      sink = reload_sink(sink)
      refute sink.is_disabled
      assert sink.errored_at
      assert sink.error_message == "IBM QRadar returned HTTP 429"
    end

    test "a 503 is transient", %{account: account} do
      sink = qradar_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(QRadar.APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 503, "")
      end)

      assert :ok = perform_job(QRadar.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      refute sink.is_disabled
      assert sink.errored_at
      assert sink.error_message == "IBM QRadar returned HTTP 503"
    end
  end

  describe "Scheduler" do
    test "enqueues sync jobs for enabled sinks on feature-enabled accounts" do
      enabled_account = account_fixture(features: %{log_sinks: true})
      sink = qradar_log_sink_fixture(account: enabled_account)
      disabled_sink = qradar_log_sink_fixture(account: enabled_account, is_disabled: true)
      feature_off_sink = qradar_log_sink_fixture()

      assert {:ok, :scheduled} = perform_job(QRadar.Scheduler, %{})

      assert_enqueued(worker: QRadar.Sync, args: %{log_sink_id: sink.id})
      refute_enqueued(worker: QRadar.Sync, args: %{log_sink_id: disabled_sink.id})
      refute_enqueued(worker: QRadar.Sync, args: %{log_sink_id: feature_off_sink.id})
    end
  end

  defp get_cursor(sink, stream, phase) do
    Repo.get_by(LogSinkCursor,
      account_id: sink.account_id,
      log_sink_id: sink.id,
      stream: stream,
      phase: phase
    )
  end

  defp reload_sink(sink) do
    Repo.get_by!(QRadar.LogSink, account_id: sink.account_id, id: sink.id)
  end
end
