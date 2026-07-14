defmodule Portal.Elastic.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.APIRequestLogFixtures
  import Portal.AccountFixtures
  import Portal.ChangeLogFixtures
  import Portal.FlowLogFixtures
  import Portal.LogSinkFixtures
  import Portal.SessionLogFixtures

  alias Portal.Elastic
  alias Portal.FlowLog
  alias Portal.LogSinkCursor

  setup do
    test_pid = self()

    Req.Test.stub(Elastic.APIClient, fn conn ->
      case conn.method do
        "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = if body == "", do: nil, else: JSON.decode!(body)
          send(test_pid, {:put, conn.request_path, decoded})

          case conn.request_path do
            "/_data_stream/" <> _ ->
              conn
              |> Plug.Conn.put_status(400)
              |> Req.Test.json(%{"error" => %{"type" => "resource_already_exists_exception"}})

            _ ->
              Req.Test.json(conn, %{"acknowledged" => true})
          end

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          lines = body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
          send(test_pid, {:bulk, conn, lines})

          items =
            lines
            |> Enum.take_every(2)
            |> Enum.map(fn _action -> %{"create" => %{"status" => 201}} end)

          Req.Test.json(conn, %{"took" => 5, "errors" => false, "items" => items})
      end
    end)

    %{account: account_fixture(features: %{log_sinks: true})}
  end

  describe "perform/1" do
    test "creates the data stream with explicit mappings", %{account: account} do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session])

      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      assert_receive {:put, "/_index_template/firezone-logs-firezone-default", template}
      assert template["index_patterns"] == ["logs-firezone-default"]
      assert template["data_stream"] == %{}

      mappings = get_in(template, ["template", "mappings"])
      assert mappings["date_detection"] == false

      firezone = get_in(mappings, ["properties", "firezone", "properties"])

      for field <- ~w[before after subject] do
        assert firezone[field]["type"] == "flattened"
      end

      assert firezone["resource_name"]["type"] == "keyword"
      assert firezone["rx_bytes"]["type"] == "long"
      assert firezone["flow_start"]["type"] == "date"

      # An already-existing data stream (the 400 the stub returns) is not an
      # error, and mappings are re-applied additively on every run so fields
      # added in later releases reach existing streams.
      assert_receive {:put, "/_data_stream/logs-firezone-default", _body}
      assert_receive {:put, "/logs-firezone-default/_mapping", mapping}
      assert get_in(mapping, ["properties", "firezone", "properties", "rx_bytes"]) ==
               %{"type" => "long"}

      log = session_log_fixture(account: account)
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      cursor = get_cursor(sink, :session, :live)
      assert cursor.cursor == log.seq
      refute reload_sink(sink).errored_at
    end

    test "every envelope field has an explicit mapping declaration", %{account: account} do
      sink = elastic_log_sink_fixture(account: account)
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      change_log_fixture(account: account)
      session_log_fixture(account: account)
      api_request_log_fixture(account: account)
      flow_log_fixture(account: account)

      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      assert_receive {:put, "/_index_template/" <> _, template}

      declared =
        get_in(template, ["template", "mappings", "properties", "firezone", "properties"])

      documents = collect_documents([])
      assert length(documents) == 4

      for document <- documents, {field, _value} <- document["firezone"] do
        assert Map.has_key?(declared, field),
               "envelope field #{field} has no explicit Elastic mapping declaration"
      end
    end

    test "bulk-creates documents with log_id as _id", %{account: account} do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      log = session_log_fixture(account: account)

      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      assert_receive {:bulk, conn, [action, document]}
      assert conn.request_path == "/_bulk"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["ApiKey " <> sink.api_key]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/x-ndjson"]
      assert action == %{"create" => %{"_index" => "logs-firezone-default", "_id" => log.log_id}}
      assert document["stream"] == "session"
      assert document["firezone"]["log_id"] == log.log_id
      assert document["@timestamp"] ==
               log.timestamp |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

      cursor = get_cursor(sink, :session, :live)
      assert cursor.cursor == log.seq
      assert cursor.synced_count == 1
    end

    test "flow start and end events get distinct document ids", %{account: account} do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:flow])
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

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

      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      assert_receive {:bulk, _conn, [start_action, _start_doc]}
      assert start_action["create"]["_id"] == flow.log_id <> "-s"

      flow_end = DateTime.utc_now()

      from(f in FlowLog,
        where: f.account_id == ^account.id,
        update: [
          set: [
            seq: fragment("nextval('flow_logs_seq_seq')"),
            flow_end: ^flow_end,
            last_packet: ^flow_end,
            rx_packets: 1,
            tx_packets: 1,
            rx_bytes: 1,
            tx_bytes: 1
          ]
        ]
      )
      |> Repo.update_all([])

      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      assert_receive {:bulk, _conn, [end_action, end_doc]}
      assert end_action["create"]["_id"] == flow.log_id <> "-e"
      assert end_doc["firezone"]["phase"] == "end"
    end

    test "version conflicts count as delivered", %{account: account} do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      log = session_log_fixture(account: account)

      Req.Test.stub(Elastic.APIClient, fn conn ->
        Req.Test.json(conn, %{
          "took" => 2,
          "errors" => true,
          "items" => [
            %{
              "create" => %{
                "status" => 409,
                "error" => %{"type" => "version_conflict_engine_exception"}
              }
            }
          ]
        })
      end)

      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      cursor = get_cursor(sink, :session, :live)
      assert cursor.cursor == log.seq
      assert cursor.synced_count == 1
      refute reload_sink(sink).errored_at
    end

    test "item-level backpressure is transient and does not advance the cursor", %{
      account: account
    } do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(Elastic.APIClient, fn conn ->
        Req.Test.json(conn, %{
          "took" => 2,
          "errors" => true,
          "items" => [
            %{
              "create" => %{
                "status" => 429,
                "error" => %{"type" => "es_rejected_execution_exception", "reason" => "queue full"}
              }
            }
          ]
        })
      end)

      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 0

      sink = reload_sink(sink)
      refute sink.is_disabled
      assert sink.errored_at
    end

    test "a poison document is isolated and dropped", %{account: account} do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      session_log_fixture(account: account, actor_email: "fine@example.com")
      session_log_fixture(account: account, actor_email: "poison@example.com")

      test_pid = self()

      Req.Test.stub(Elastic.APIClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        lines = body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
        documents = lines |> Enum.drop_every(2)

        items =
          Enum.map(documents, fn document ->
            if document["firezone"]["subject"]["actor_email"] == "poison@example.com" do
              %{
                "create" => %{
                  "status" => 400,
                  "error" => %{"type" => "document_parsing_exception", "reason" => "bad field"}
                }
              }
            else
              send(test_pid, {:indexed, document["firezone"]["log_id"]})
              %{"create" => %{"status" => 201}}
            end
          end)

        errors = Enum.any?(items, fn item -> item["create"]["status"] != 201 end)
        Req.Test.json(conn, %{"took" => 2, "errors" => errors, "items" => items})
      end)

      log_output =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
        end)

      # Drops page us via error-level logs but never touch the sink's
      # customer-facing error state: a rejected document is our schema bug,
      # not something an admin can fix by editing the sink.
      assert log_output =~ "Dropping undeliverable log sink event"
      assert log_output =~ "bad field"

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 1
      assert cursor.dropped_count == 1

      sink = reload_sink(sink)
      refute sink.is_disabled
      refute sink.errored_at
      refute sink.error_message
    end

    test "a 401 disables the sink immediately", %{account: account} do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account)

      Req.Test.stub(Elastic.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"reason" => "unable to authenticate user"}})
      end)

      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      sink = reload_sink(sink)
      assert sink.is_disabled
      assert sink.disabled_reason == "Sync error"

      assert sink.error_message ==
               "Elasticsearch returned HTTP 401: unable to authenticate user"
    end
  end

  describe "Scheduler" do
    test "enqueues sync jobs for enabled sinks on feature-enabled accounts" do
      enabled_account = account_fixture(features: %{log_sinks: true})
      sink = elastic_log_sink_fixture(account: enabled_account)
      disabled_sink = elastic_log_sink_fixture(account: enabled_account, is_disabled: true)
      feature_off_sink = elastic_log_sink_fixture()

      assert {:ok, :scheduled} = perform_job(Elastic.Scheduler, %{})

      assert_enqueued(worker: Elastic.Sync, args: %{log_sink_id: sink.id})
      refute_enqueued(worker: Elastic.Sync, args: %{log_sink_id: disabled_sink.id})
      refute_enqueued(worker: Elastic.Sync, args: %{log_sink_id: feature_off_sink.id})
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
    Repo.get_by!(Elastic.LogSink, account_id: sink.account_id, id: sink.id)
  end

  defp collect_documents(acc) do
    receive do
      {:bulk, _conn, lines} -> collect_documents(acc ++ Enum.drop_every(lines, 2))
    after
      0 -> acc
    end
  end
end
