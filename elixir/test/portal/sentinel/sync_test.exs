defmodule Portal.Sentinel.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.LogSinkFixtures
  import Portal.SessionLogFixtures

  alias Portal.LogSinkCursor
  alias Portal.Sentinel

  setup do
    test_pid = self()

    Req.Test.stub(Sentinel.APIClient, fn conn ->
      case conn.host do
        "login.microsoftonline.com" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:token, conn, URI.decode_query(body)})

          Req.Test.json(conn, %{
            "access_token" => "test-access-token",
            "token_type" => "Bearer",
            "expires_in" => 3599
          })

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:ingest, conn, JSON.decode!(body)})

          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    %{account: account_fixture(features: %{log_sinks: true})}
  end

  describe "perform/1" do
    test "delivers a JSON array of enveloped events with a customer-tenant token", %{
      account: account
    } do
      sink = sentinel_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})

      refute_receive {:token, _conn, _params}

      log = session_log_fixture(account: account)

      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})

      assert_receive {:token, token_conn, token_params}
      assert token_conn.request_path == "/#{sink.tenant_id}/oauth2/v2.0/token"
      assert token_params["grant_type"] == "client_credentials"
      assert token_params["client_id"] == "test_sentinel_client_id"
      assert token_params["client_secret"] == "test_sentinel_client_secret"
      assert token_params["scope"] == "https://monitor.azure.com//.default"

      assert_receive {:ingest, conn, [event]}

      assert conn.request_path ==
               "/dataCollectionRules/#{sink.dcr_immutable_id}/streams/Custom-FirezoneLogs_CL"

      assert conn.query_string == "api-version=2023-01-01"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-access-token"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert event["Stream"] == "session"
      assert event["Message"] =~ log.log_id
      assert event["Firezone"]["log_id"] == log.log_id

      assert event["TimeGenerated"] ==
               log.timestamp |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

      cursor = get_cursor(sink, :session, :live)
      assert cursor.cursor == log.seq
      assert cursor.synced_count == 1
      refute reload_sink(sink).errored_at
    end

    test "a token error for a missing service principal disables the sink", %{account: account} do
      sink = sentinel_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(Sentinel.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => "unauthorized_client",
          "error_description" =>
            "AADSTS700016: Application with identifier 'abc' was not found in the directory " <>
              "'Contoso'.\r\nTrace ID: 0000"
        })
      end)

      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message =~ "AADSTS700016"
      assert sink.error_message =~ "admin consent"
    end

    test "a 403 is transient while the role propagates and names it", %{account: account} do
      sink = sentinel_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      stub_ingest_status(403, %{
        "error" => %{
          "code" => "OperationFailed",
          "message" => "The authentication token doesn't have access to perform the operation."
        }
      })

      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      refute sink.is_disabled
      assert sink.errored_at
      assert sink.error_message =~ "Azure Monitor returned HTTP 403"
      assert sink.error_message =~ "Firezone Sentinel Log Ingestion service principal"
      refute sink.error_message =~ ".."
    end

    test "authenticates with a managed-identity assertion when no secret is set", %{
      account: account
    } do
      Portal.Config.put_env_override(:portal, Sentinel.APIClient, client_secret: nil)

      Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "mi-federation-assertion",
          "expires_on" => Integer.to_string(System.system_time(:second) + 3600)
        })
      end)

      sink = sentinel_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)
      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})

      assert_receive {:token, _conn, params}
      assert params["client_assertion"] == "mi-federation-assertion"

      assert params["client_assertion_type"] ==
               "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

      refute params["client_secret"]

      assert_receive {:ingest, _conn, [_event]}
      refute reload_sink(sink).errored_at
    end

    test "an invalid stream 400 is a customer-facing transient error", %{account: account} do
      sink = sentinel_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})
      log = session_log_fixture(account: account)

      stub_ingest_status(400, %{
        "error" => %{
          "code" => "InvalidStream",
          "message" => "The stream Custom-Wrong_CL was not configured in the data collection rule."
        }
      })

      log_output =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})
        end)

      refute log_output =~ "cannot be delivered"

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 0
      assert cursor.cursor < log.seq

      sink = reload_sink(sink)
      refute sink.is_disabled
      assert sink.errored_at
      assert sink.error_message =~ "was not configured in the data collection rule"
      assert sink.error_message =~ "stream name and DCR immutable ID"
      refute sink.error_message =~ ".."
    end

    test "a malformed-request 400 parks the stream without alarming the customer", %{
      account: account
    } do
      sink = sentinel_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})
      log = session_log_fixture(account: account)

      stub_ingest_status(400, %{
        "error" => %{
          "code" => "InvalidContentLength",
          "message" => "Content-Length must be greater than zero."
        }
      })

      log_output =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})
        end)

      assert log_output =~ "Log sink event cannot be delivered, halting stream"

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 0
      assert cursor.cursor < log.seq

      sink = reload_sink(sink)
      refute sink.is_disabled
      refute sink.errored_at
      refute sink.error_message
    end

    test "a 429 is transient", %{account: account} do
      sink = sentinel_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      stub_ingest_status(429, %{
        "error" => %{"code" => "TooManyRequests", "message" => "Rate limit exceeded"}
      })

      assert :ok = perform_job(Sentinel.Sync, %{log_sink_id: sink.id})

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 0

      sink = reload_sink(sink)
      refute sink.is_disabled
      assert sink.errored_at
      assert sink.error_message == "Azure Monitor returned HTTP 429: Rate limit exceeded"
    end
  end

  describe "Scheduler" do
    test "enqueues sync jobs for enabled sinks on feature-enabled accounts" do
      enabled_account = account_fixture(features: %{log_sinks: true})
      sink = sentinel_log_sink_fixture(account: enabled_account)
      disabled_sink = sentinel_log_sink_fixture(account: enabled_account, is_disabled: true)
      feature_off_sink = sentinel_log_sink_fixture()

      assert {:ok, :scheduled} = perform_job(Sentinel.Scheduler, %{})

      assert_enqueued(worker: Sentinel.Sync, args: %{log_sink_id: sink.id})
      refute_enqueued(worker: Sentinel.Sync, args: %{log_sink_id: disabled_sink.id})
      refute_enqueued(worker: Sentinel.Sync, args: %{log_sink_id: feature_off_sink.id})
    end
  end

  defp stub_ingest_status(status, body) do
    Req.Test.stub(Sentinel.APIClient, fn conn ->
      case conn.host do
        "login.microsoftonline.com" ->
          Req.Test.json(conn, %{
            "access_token" => "test-access-token",
            "token_type" => "Bearer",
            "expires_in" => 3599
          })

        _ ->
          conn
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(body)
      end
    end)
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
    Repo.get_by!(Sentinel.LogSink, account_id: sink.account_id, id: sink.id)
  end
end
