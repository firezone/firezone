defmodule Portal.Datadog.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.LogSinkFixtures
  import Portal.SessionLogFixtures

  alias Portal.Datadog
  alias Portal.LogSinkCursor

  setup do
    test_pid = self()

    Req.Test.stub(Datadog.APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:intake, conn, JSON.decode!(body)})

      conn
      |> Plug.Conn.put_status(202)
      |> Req.Test.json(%{})
    end)

    %{account: account_fixture(features: %{log_sinks: true})}
  end

  describe "perform/1" do
    test "delivers a JSON array of enveloped events", %{account: account} do
      sink = datadog_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Datadog.Sync, %{log_sink_id: sink.id})

      log = session_log_fixture(account: account)

      assert :ok = perform_job(Datadog.Sync, %{log_sink_id: sink.id})

      assert_receive {:intake, conn, [event]}
      assert conn.request_path == "/api/v2/logs"
      assert conn.host == "http-intake.logs.datadoghq.com"
      assert Plug.Conn.get_req_header(conn, "dd-api-key") == [sink.api_key]
      assert event["ddsource"] == "firezone"
      assert event["ddtags"] == "stream:session"
      assert event["service"] == "firezone"
      assert event["message"] =~ log.log_id
      assert event["firezone"]["type"] == "session"
      assert event["firezone"]["log_id"] == log.log_id
      assert event["timestamp"] == DateTime.to_unix(log.timestamp, :millisecond)

      cursor =
        Repo.get_by(LogSinkCursor,
          account_id: account.id,
          log_sink_id: sink.id,
          stream: :session,
          phase: :live
        )

      assert cursor.cursor == log.seq
      assert cursor.synced_count == 1
    end

    test "a 403 disables the sink immediately", %{account: account} do
      sink = datadog_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Datadog.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(Datadog.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"errors" => [%{"detail" => "Invalid API key"}]})
      end)

      assert :ok = perform_job(Datadog.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message == "Datadog returned HTTP 403: Invalid API key"
    end

    test "a 429 is transient", %{account: account} do
      sink = datadog_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Datadog.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(Datadog.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"errors" => ["Too many requests"]})
      end)

      assert :ok = perform_job(Datadog.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      refute sink.is_disabled
      assert sink.errored_at
      assert sink.error_message == "Datadog returned HTTP 429: Too many requests"
    end
  end

  describe "Scheduler" do
    test "enqueues sync jobs for enabled sinks on feature-enabled accounts" do
      enabled_account = account_fixture(features: %{log_sinks: true})
      sink = datadog_log_sink_fixture(account: enabled_account)
      disabled_sink = datadog_log_sink_fixture(account: enabled_account, is_disabled: true)
      feature_off_sink = datadog_log_sink_fixture()

      assert {:ok, :scheduled} = perform_job(Datadog.Scheduler, %{})

      assert_enqueued(worker: Datadog.Sync, args: %{log_sink_id: sink.id})
      refute_enqueued(worker: Datadog.Sync, args: %{log_sink_id: disabled_sink.id})
      refute_enqueued(worker: Datadog.Sync, args: %{log_sink_id: feature_off_sink.id})
    end
  end

  defp reload_sink(sink) do
    Repo.get_by!(Datadog.LogSink, account_id: sink.account_id, id: sink.id)
  end
end
