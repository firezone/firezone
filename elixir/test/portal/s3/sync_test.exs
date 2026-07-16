defmodule Portal.S3.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.LogSinkFixtures
  import Portal.SessionLogFixtures

  alias Portal.LogSinkCursor
  alias Portal.S3

  @sts_response """
  <AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
    <AssumeRoleResult>
      <Credentials>
        <AccessKeyId>ASIATESTASSUMEDKEY</AccessKeyId>
        <SecretAccessKey>test-assumed-secret</SecretAccessKey>
        <SessionToken>test-session-token</SessionToken>
        <Expiration>2030-01-01T00:00:00Z</Expiration>
      </Credentials>
    </AssumeRoleResult>
  </AssumeRoleResponse>
  """

  @sts_access_denied """
  <ErrorResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
    <Error>
      <Type>Sender</Type>
      <Code>AccessDenied</Code>
      <Message>User is not authorized to perform: sts:AssumeRole</Message>
    </Error>
    <RequestId>0000</RequestId>
  </ErrorResponse>
  """

  setup do
    test_pid = self()

    Req.Test.stub(S3.APIClient, fn conn ->
      case conn.host do
        "sts." <> _rest ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(body)
          send(test_pid, {:sts, conn, params})

          "firezone-" <> sink_id = params["RoleSessionName"]
          sink = Portal.Repo.get_by!(S3.LogSink, id: sink_id)

          if params["ExternalId"] == sink.external_id do
            Plug.Conn.resp(conn, 200, @sts_response)
          else
            Plug.Conn.resp(conn, 403, @sts_access_denied)
          end

        _bucket_host ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:put_object, conn, body})

          Plug.Conn.resp(conn, 200, "")
      end
    end)

    %{account: account_fixture(features: %{log_sinks: true})}
  end

  describe "perform/1" do
    test "assumes the role and writes an NDJSON object with a deterministic key", %{
      account: account
    } do
      sink =
        s3_log_sink_fixture(
          account: account,
          enabled_streams: [:session],
          key_prefix: "firezone/logs"
        )

      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})

      log = session_log_fixture(account: account)

      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})

      assert_receive {:sts, _probe_conn, probe_params}
      assert probe_params["RoleArn"] == sink.role_arn
      refute probe_params["ExternalId"] == sink.external_id

      assert_receive {:sts, sts_conn, params}
      assert sts_conn.host == "sts.us-east-1.amazonaws.com"
      assert params["Action"] == "AssumeRole"
      assert params["RoleArn"] == sink.role_arn
      assert params["ExternalId"] == sink.external_id
      [sts_authorization] = Plug.Conn.get_req_header(sts_conn, "authorization")
      assert sts_authorization =~ "AWS4-HMAC-SHA256"
      assert sts_authorization =~ "test-aws-access-key-id"

      assert_receive {:put_object, conn, body}
      assert conn.method == "PUT"
      assert conn.host == "#{sink.bucket}.s3.us-east-1.amazonaws.com"

      date = Calendar.strftime(log.timestamp, "%Y/%m/%d")
      assert conn.request_path == "/firezone/logs/session/#{date}/#{log.seq}-#{log.seq}.ndjson"

      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      assert authorization =~ "AWS4-HMAC-SHA256"
      assert authorization =~ "ASIATESTASSUMEDKEY"
      assert authorization =~ "/us-east-1/s3/aws4_request"
      assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["test-session-token"]
      assert [_sha256] = Plug.Conn.get_req_header(conn, "x-amz-content-sha256")

      assert [event] =
               body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert event["type"] == "session"
      assert event["log_id"] == log.log_id

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

    test "redelivery after a transient failure reuses the same object key", %{account: account} do
      sink = s3_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      test_pid = self()

      Req.Test.stub(S3.APIClient, fn conn ->
        case conn.host do
          "sts." <> _rest ->
            sts_reply(conn)

          _bucket_host ->
            send(test_pid, {:put_object_key, conn.request_path})

            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(503, "<Error><Code>SlowDown</Code><Message>Slow down</Message></Error>")
        end
      end)

      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})
      assert_receive {:put_object_key, first_key}

      sink_after_failure = reload_sink(sink)
      refute sink_after_failure.is_disabled
      assert sink_after_failure.errored_at

      Req.Test.stub(S3.APIClient, fn conn ->
        case conn.host do
          "sts." <> _rest ->
            sts_reply(conn)

          _bucket_host ->
            send(test_pid, {:put_object_key, conn.request_path})
            Plug.Conn.resp(conn, 200, "")
        end
      end)

      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})
      assert_receive {:put_object_key, second_key}

      assert first_key == second_key
      refute reload_sink(sink).errored_at
    end

    test "a role that ignores the external id disables the sink", %{account: account} do
      sink = s3_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(S3.APIClient, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.resp(conn, 200, @sts_response)
      end)

      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message =~ "does not require this sink's External ID"
    end

    test "an STS AccessDenied disables the sink with an actionable message", %{account: account} do
      sink = s3_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(S3.APIClient, fn conn ->
        Plug.Conn.resp(conn, 403, @sts_access_denied)
      end)

      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message =~ "AccessDenied"
      assert sink.error_message =~ "trust policy"
      assert sink.error_message =~ "External ID"
    end

    test "a wrong-region redirect disables the sink with the bucket's region", %{
      account: account
    } do
      sink = s3_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(S3.APIClient, fn conn ->
        case conn.host do
          "sts." <> _rest ->
            sts_reply(conn)

          _bucket_host ->
            conn
            |> Plug.Conn.put_resp_header("x-amz-bucket-region", "eu-west-1")
            |> Plug.Conn.resp(
              301,
              "<Error><Code>PermanentRedirect</Code><Message>Wrong endpoint</Message></Error>"
            )
        end
      end)

      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message =~ "the bucket is in eu-west-1"
    end

    test "a 403 from S3 disables the sink immediately", %{account: account} do
      sink = s3_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(S3.APIClient, fn conn ->
        case conn.host do
          "sts." <> _rest ->
            sts_reply(conn)

          _bucket_host ->
            Plug.Conn.resp(
              conn,
              403,
              "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>"
            )
        end
      end)

      assert :ok = perform_job(S3.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.error_message == "Amazon S3 returned HTTP 403 (AccessDenied): Access Denied"
    end
  end

  describe "Scheduler" do
    test "enqueues sync jobs for enabled sinks on feature-enabled accounts" do
      enabled_account = account_fixture(features: %{log_sinks: true})
      sink = s3_log_sink_fixture(account: enabled_account)
      disabled_sink = s3_log_sink_fixture(account: enabled_account, is_disabled: true)
      feature_off_sink = s3_log_sink_fixture()

      assert {:ok, :scheduled} = perform_job(S3.Scheduler, %{})

      assert_enqueued(worker: S3.Sync, args: %{log_sink_id: sink.id})
      refute_enqueued(worker: S3.Sync, args: %{log_sink_id: disabled_sink.id})
      refute_enqueued(worker: S3.Sync, args: %{log_sink_id: feature_off_sink.id})
    end
  end

  defp sts_reply(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = URI.decode_query(body)
    "firezone-" <> sink_id = params["RoleSessionName"]
    sink = Portal.Repo.get_by!(S3.LogSink, id: sink_id)

    if params["ExternalId"] == sink.external_id do
      Plug.Conn.resp(conn, 200, @sts_response)
    else
      Plug.Conn.resp(conn, 403, @sts_access_denied)
    end
  end

  defp reload_sink(sink) do
    Repo.get_by!(S3.LogSink, account_id: sink.account_id, id: sink.id)
  end
end
