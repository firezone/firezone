defmodule Portal.HTTP.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.FlowLogFixtures
  import Portal.LogSinkFixtures
  import Portal.SessionLogFixtures

  alias Portal.HTTP
  alias Portal.LogSinkCursor

  setup do
    test_pid = self()

    Req.Test.stub(HTTP.APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:post, conn, JSON.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    %{account: account_fixture(features: %{log_sinks: true})}
  end

  describe "perform/1" do
    test "delivers a JSON array of events with the bearer token", %{account: account} do
      sink = http_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})
      refute_receive {:post, _conn, _events}

      log = session_log_fixture(account: account)

      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})

      assert_receive {:post, conn, [event]}
      assert conn.request_path == "/ingest"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> sink.bearer_token]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert event["type"] == "session"
      assert event["log_id"] == log.log_id
      assert event["timestamp"] == DateTime.to_iso8601(log.timestamp)

      cursor = get_cursor(sink, :session, :live)
      assert cursor.cursor == log.seq
      assert cursor.synced_count == 1
      refute reload_sink(sink).errored_at
    end

    test "omits the authorization header without a bearer token", %{account: account} do
      sink =
        http_log_sink_fixture(account: account, bearer_token: nil, enabled_streams: [:session])

      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})

      assert_receive {:post, conn, [_event]}
      assert Plug.Conn.get_req_header(conn, "authorization") == []
    end

    test "batch_max_events caps events per request", %{account: account} do
      sink =
        http_log_sink_fixture(account: account, batch_max_events: 2, enabled_streams: [:session])

      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})

      logs = for _ <- 1..5, do: session_log_fixture(account: account)

      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})

      batches =
        for _ <- 1..3 do
          assert_receive {:post, _conn, events}
          events
        end

      refute_receive {:post, _conn, _events}
      assert Enum.map(batches, &length/1) == [2, 2, 1]

      assert batches |> List.flatten() |> Enum.map(& &1["log_id"]) ==
               Enum.map(logs, & &1.log_id)

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 5
    end

    test "a flow start/end pair never splits across batches", %{account: account} do
      sink =
        http_log_sink_fixture(account: account, batch_max_events: 1, enabled_streams: [:flow])

      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})

      flow1 = flow_log_fixture(account: account)
      flow2 = flow_log_fixture(account: account)

      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})

      assert_receive {:post, _conn, [start1, end1]}
      assert start1["log_id"] == flow1.log_id <> "-s"
      assert end1["log_id"] == flow1.log_id <> "-e"

      assert_receive {:post, _conn, [start2, end2]}
      assert start2["log_id"] == flow2.log_id <> "-s"
      assert end2["log_id"] == flow2.log_id <> "-e"

      refute_receive {:post, _conn, _events}
    end

    test "a 401 disables the sink immediately with the response excerpt", %{account: account} do
      sink = http_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(HTTP.APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 401, "invalid token")
      end)

      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message == "The endpoint returned HTTP 401: invalid token"
    end

    test "a 429 is transient", %{account: account} do
      sink = http_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(HTTP.APIClient, fn conn ->
        Plug.Conn.send_resp(conn, 429, "slow down")
      end)

      assert :ok = perform_job(HTTP.Sync, %{log_sink_id: sink.id})

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 0

      sink = reload_sink(sink)
      refute sink.is_disabled
      assert sink.errored_at
      assert sink.error_message == "The endpoint returned HTTP 429: slow down"
    end
  end

  describe "Scheduler" do
    test "enqueues sync jobs for enabled sinks on feature-enabled accounts" do
      enabled_account = account_fixture(features: %{log_sinks: true})
      sink = http_log_sink_fixture(account: enabled_account)
      disabled_sink = http_log_sink_fixture(account: enabled_account, is_disabled: true)
      feature_off_sink = http_log_sink_fixture()

      assert {:ok, :scheduled} = perform_job(HTTP.Scheduler, %{})

      assert_enqueued(worker: HTTP.Sync, args: %{log_sink_id: sink.id})
      refute_enqueued(worker: HTTP.Sync, args: %{log_sink_id: disabled_sink.id})
      refute_enqueued(worker: HTTP.Sync, args: %{log_sink_id: feature_off_sink.id})
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
    Repo.get_by!(HTTP.LogSink, account_id: sink.account_id, id: sink.id)
  end
end
