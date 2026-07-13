defmodule Portal.Splunk.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.APIRequestLogFixtures
  import Portal.AccountFixtures
  import Portal.ChangeLogFixtures
  import Portal.FlowLogFixtures
  import Portal.LogSinkFixtures
  import Portal.SessionLogFixtures

  alias Portal.FlowLog
  alias Portal.LogSinkCursor
  alias Portal.Splunk

  setup do
    test_pid = self()

    Req.Test.stub(Splunk.APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      events = body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      send(test_pid, {:hec, conn, events})
      Req.Test.json(conn, %{"text" => "Success", "code" => 0})
    end)

    %{account: account_fixture()}
  end

  describe "perform/1" do
    test "seeds live cursors on first run and delivers only later logs", %{account: account} do
      session_log_fixture(account: account)
      sink = splunk_log_sink_fixture(account: account)

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})
      refute_receive {:hec, _conn, _events}

      log = session_log_fixture(account: account)

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      assert_receive {:hec, conn, [event]}
      assert conn.request_path == "/services/collector/event"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Splunk " <> sink.hec_token]
      assert event["source"] == "firezone"
      assert event["sourcetype"] == "firezone:session"
      assert event["event"]["type"] == "session"
      assert event["event"]["log_id"] == log.log_id
      assert_in_delta event["time"], DateTime.to_unix(log.timestamp, :millisecond) / 1000, 0.001

      cursor = get_cursor(sink, :session, :live)
      assert cursor.cursor == log.seq
      assert cursor.synced_count == 1
      assert cursor.last_synced_at

      sink = Repo.reload!(sink)
      assert sink.is_verified
    end

    test "delivers every enabled stream with its own sourcetype", %{account: account} do
      sink = splunk_log_sink_fixture(account: account)
      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      change_log_fixture(account: account)
      session_log_fixture(account: account)
      api_request_log_fixture(account: account)
      flow_log_fixture(account: account)

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      sourcetypes =
        for _batch <- 1..4 do
          assert_receive {:hec, _conn, [event]}
          event["sourcetype"]
        end

      assert Enum.sort(sourcetypes) ==
               ~w[firezone:api_request firezone:change firezone:flow firezone:session]
    end

    test "a retroactive sink backfills logs that predate it", %{account: account} do
      for _ <- 1..3 do
        session_log_fixture(account: account)
      end

      sink =
        splunk_log_sink_fixture(
          account: account,
          retroactive: true,
          enabled_streams: [:session]
        )

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      assert_receive {:hec, _conn, events}
      assert length(events) == 3

      backfill = get_cursor(sink, :session, :backfill)
      assert backfill.backfill_total == 3
      assert backfill.synced_count == 3
      assert backfill.completed_at

      assert get_cursor(sink, :session, :live)
    end

    test "a closed flow is delivered again as an end event", %{account: account} do
      sink = splunk_log_sink_fixture(account: account, enabled_streams: [:flow])
      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      flow =
        flow_log_fixture(
          account: account,
          flow_end: nil,
          last_packet: nil,
          rx_packets: nil,
          tx_packets: nil,
          rx_bytes: nil,
          tx_bytes: nil
        )

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      assert_receive {:hec, _conn, [start_event]}
      assert start_event["event"]["phase"] == "start"
      assert start_event["event"]["log_id"] == flow.log_id
      assert_in_delta start_event["time"],
                      DateTime.to_unix(flow.flow_start, :millisecond) / 1000,
                      0.001

      flow_end = DateTime.utc_now()

      from(f in FlowLog,
        where: f.account_id == ^account.id,
        update: [
          set: [
            seq: fragment("nextval('flow_logs_seq_seq')"),
            flow_end: ^flow_end,
            last_packet: ^flow_end,
            rx_packets: 10,
            tx_packets: 12,
            rx_bytes: 1024,
            tx_bytes: 2048
          ]
        ]
      )
      |> Repo.update_all([])

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      assert_receive {:hec, _conn, [end_event]}
      assert end_event["event"]["phase"] == "end"
      assert end_event["event"]["log_id"] == flow.log_id
      assert end_event["event"]["rx_bytes"] == 1024
      assert_in_delta end_event["time"], DateTime.to_unix(flow_end, :millisecond) / 1000, 0.001
    end

    test "a 4xx response disables the sink immediately", %{account: account} do
      sink = splunk_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(Splunk.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"text" => "Invalid token", "code" => 4})
      end)

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      sink = Repo.reload!(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
      assert sink.errored_at
      assert sink.error_message == "Splunk HEC returned HTTP 403: Invalid token"
      refute sink.is_verified

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 0
    end

    test "transient errors disable the sink only after 24 hours", %{account: account} do
      sink = splunk_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(Splunk.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"text" => "Server is busy", "code" => 9})
      end)

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      sink = Repo.reload!(sink)
      refute sink.is_disabled
      assert sink.errored_at
      assert sink.error_message == "Splunk HEC returned HTTP 503: Server is busy"

      stale_errored_at = DateTime.add(DateTime.utc_now(), -25, :hour)

      {:ok, sink} =
        sink
        |> Ecto.Changeset.change(errored_at: stale_errored_at)
        |> Repo.update()

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      sink = Repo.reload!(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"
    end

    test "transport errors are transient", %{account: account} do
      sink = splunk_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(Splunk.APIClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      sink = Repo.reload!(sink)
      refute sink.is_disabled
      assert sink.errored_at
      assert sink.error_message == "Connection refused."
    end

    test "a successful delivery clears previous error state", %{account: account} do
      sink =
        splunk_log_sink_fixture(
          account: account,
          enabled_streams: [:session],
          errored_at: DateTime.utc_now(),
          error_message: "Splunk HEC returned HTTP 503: Server is busy"
        )

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

      sink = Repo.reload!(sink)
      refute sink.errored_at
      refute sink.error_message
      assert sink.is_verified
    end

    test "skips sinks that are disabled or missing", %{account: account} do
      sink = splunk_log_sink_fixture(account: account, is_disabled: true)

      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})
      assert :ok = perform_job(Splunk.Sync, %{log_sink_id: Ecto.UUID.generate()})

      refute_receive {:hec, _conn, _events}
      assert Repo.all(LogSinkCursor) == []
    end
  end

  describe "Scheduler" do
    test "enqueues sync jobs for enabled sinks on feature-enabled accounts" do
      enabled_account = account_fixture(features: %{log_sinks: true})
      sink = splunk_log_sink_fixture(account: enabled_account)
      disabled_sink = splunk_log_sink_fixture(account: enabled_account, is_disabled: true)
      feature_off_sink = splunk_log_sink_fixture()

      assert {:ok, :scheduled} = perform_job(Splunk.Scheduler, %{})

      assert_enqueued(worker: Splunk.Sync, args: %{log_sink_id: sink.id})
      refute_enqueued(worker: Splunk.Sync, args: %{log_sink_id: disabled_sink.id})
      refute_enqueued(worker: Splunk.Sync, args: %{log_sink_id: feature_off_sink.id})
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
end
