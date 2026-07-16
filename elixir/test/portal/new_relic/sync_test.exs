defmodule Portal.NewRelic.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.LogSinkFixtures
  import Portal.SessionLogFixtures

  alias Portal.LogSinkCursor
  alias Portal.NewRelic

  setup do
    test_pid = self()

    Req.Test.stub(NewRelic.APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:intake, conn, JSON.decode!(body)})

      conn
      |> Plug.Conn.put_status(202)
      |> Req.Test.json(%{"requestId" => "test-request-id"})
    end)

    %{account: account_fixture(features: %{log_sinks: true})}
  end

  describe "perform/1" do
    test "delivers the detailed payload format", %{account: account} do
      sink = newrelic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})

      log = session_log_fixture(account: account)

      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})

      assert_receive {:intake, conn, [%{"logs" => [event]}]}
      assert conn.request_path == "/log/v1"
      assert conn.host == "log-api.newrelic.com"
      assert Plug.Conn.get_req_header(conn, "api-key") == [sink.license_key]
      assert event["timestamp"] == DateTime.to_unix(log.timestamp, :millisecond)
      assert event["message"] =~ log.log_id
      assert event["attributes"]["logtype"] == "firezone"
      assert event["attributes"]["stream"] == "session"
      assert event["attributes"]["firezone"]["type"] == "session"
      assert event["attributes"]["firezone"]["log_id"] == log.log_id

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

    test "uses the region's endpoint", %{account: account} do
      sink =
        newrelic_log_sink_fixture(
          account: account,
          region: "EU",
          enabled_streams: [:session]
        )

      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)
      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})

      assert_receive {:intake, conn, _payload}
      assert conn.host == "log-api.eu.newrelic.com"
    end

    test "Japan routes to the nr-data.net endpoint", %{account: account} do
      sink =
        newrelic_log_sink_fixture(
          account: account,
          region: "JP",
          enabled_streams: [:session]
        )

      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)
      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})

      assert_receive {:intake, conn, _payload}
      assert conn.host == "log-api.jp.nr-data.net"
    end

    test "a 403 disables the sink immediately", %{account: account} do
      sink = newrelic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(NewRelic.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"message" => "Invalid license key"})
      end)

      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message == "New Relic returned HTTP 403: Invalid license key"
    end

    test "a 429 is transient", %{account: account} do
      sink = newrelic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(NewRelic.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"message" => "Too many requests"})
      end)

      assert :ok = perform_job(NewRelic.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      refute sink.is_disabled
      assert sink.errored_at
    end
  end

  describe "Scheduler" do
    test "enqueues sync jobs for enabled sinks on feature-enabled accounts" do
      enabled_account = account_fixture(features: %{log_sinks: true})
      sink = newrelic_log_sink_fixture(account: enabled_account)
      disabled_sink = newrelic_log_sink_fixture(account: enabled_account, is_disabled: true)
      feature_off_sink = newrelic_log_sink_fixture()

      assert {:ok, :scheduled} = perform_job(NewRelic.Scheduler, %{})

      assert_enqueued(worker: NewRelic.Sync, args: %{log_sink_id: sink.id})
      refute_enqueued(worker: NewRelic.Sync, args: %{log_sink_id: disabled_sink.id})
      refute_enqueued(worker: NewRelic.Sync, args: %{log_sink_id: feature_off_sink.id})
    end
  end

  defp reload_sink(sink) do
    Repo.get_by!(NewRelic.LogSink, account_id: sink.account_id, id: sink.id)
  end
end
