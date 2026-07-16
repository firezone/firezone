defmodule Portal.Elastic.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
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
    test "creates the data stream with type rules instead of a field list", %{account: account} do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session])

      # An idle run has nothing to deliver and makes no destination calls.
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      refute_receive {:put, _path, _body}

      session_log_fixture(account: account)
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      assert_receive {:put, "/_index_template/firezone-logs-firezone-default", template}
      assert template["index_patterns"] == ["logs-firezone-default"]
      assert template["data_stream"] == %{}

      mappings = get_in(template, ["template", "mappings"])
      assert mappings["date_detection"] == false
      refute mappings["properties"]

      rules =
        mappings["dynamic_templates"]
        |> Enum.flat_map(&Map.values/1)
        |> Map.new(fn rule -> {rule["match_mapping_type"], rule["mapping"]} end)

      assert rules["object"]["type"] == "flattened"
      assert rules["string"]["type"] == "keyword"

      # An already-existing data stream (the 400 the stub returns) is not an
      # error, and the rules are re-applied on every run so template repairs
      # reach existing streams.
      assert_receive {:put, "/_data_stream/logs-firezone-default", _body}
      assert_receive {:put, "/logs-firezone-default/_mapping", mapping}
      assert mapping["dynamic_templates"]

      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 1
      refute reload_sink(sink).errored_at
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
            start_seq: f.seq,
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
      assert end_doc["firezone"]["log_id"] == flow.log_id <> "-e"
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

    test "a mapping rejection parks the stream and rolls the data stream over", %{
      account: account
    } do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      fine = session_log_fixture(account: account, actor_email: "fine@example.com")
      poison = session_log_fixture(account: account, actor_email: "poison@example.com")

      stub_with_poison(self(), "document_parsing_exception")

      log_output =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
        end)

      assert log_output =~ "Log sink event cannot be delivered, halting stream"

      assert_receive {:rollover, "/logs-firezone-default/_rollover"}

      # The healthy prefix is delivered and the cursor parks just before the
      # poison event: nothing is skipped, and after the rollover the next run
      # can deliver it against the corrected mappings.
      cursor = get_cursor(sink, :session, :live)
      assert cursor.synced_count == 1
      assert cursor.dropped_count == 0
      assert cursor.cursor == fine.seq
      assert cursor.cursor < poison.seq

      sink = reload_sink(sink)
      assert sink.last_rollover_at
      refute sink.is_disabled
      refute sink.errored_at
      refute sink.error_message
    end

    test "rollovers are rate limited by the cooldown", %{account: account} do
      sink =
        elastic_log_sink_fixture(
          account: account,
          enabled_streams: [:session],
          last_rollover_at: DateTime.utc_now()
        )

      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      session_log_fixture(account: account, actor_email: "poison@example.com")

      stub_with_poison(self(), "document_parsing_exception")

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      end)

      refute_receive {:rollover, _path}
    end

    test "a non-mapping rejection is a customer-facing transient error", %{account: account} do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session])
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      poison = session_log_fixture(account: account, actor_email: "poison@example.com")

      stub_with_poison(self(), "cluster_block_exception")

      log_output =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
        end)

      refute log_output =~ "cannot be delivered"
      refute_receive {:rollover, _path}

      cursor = get_cursor(sink, :session, :live)
      assert cursor.cursor < poison.seq
      assert cursor.synced_count == 0

      sink = reload_sink(sink)
      refute sink.is_disabled
      refute sink.last_rollover_at
      assert sink.errored_at
      assert sink.error_message =~ "Elasticsearch rejected documents"
      assert sink.error_message =~ "bad field"
    end

    test "parallel streams cannot roll the data stream over twice in one run", %{
      account: account
    } do
      sink = elastic_log_sink_fixture(account: account, enabled_streams: [:session, :flow])
      assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})

      session_log_fixture(account: account)
      flow_log_fixture(account: account, domain: "example.com")

      test_pid = self()

      Req.Test.stub(Elastic.APIClient, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        cond do
          conn.method == "PUT" ->
            Req.Test.json(conn, %{"acknowledged" => true})

          String.ends_with?(conn.request_path, "/_rollover") ->
            send(test_pid, {:rollover, conn.request_path})
            Req.Test.json(conn, %{"acknowledged" => true, "rolled_over" => true})

          true ->
            Req.Test.json(conn, %{
              "errors" => true,
              "items" => [
                %{
                  "create" => %{
                    "status" => 400,
                    "error" => %{"type" => "mapper_parsing_exception", "reason" => "bad"}
                  }
                }
              ]
            })
        end
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = perform_job(Elastic.Sync, %{log_sink_id: sink.id})
      end)

      assert_receive {:rollover, _path}
      refute_receive {:rollover, _path}
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

  defp stub_with_poison(test_pid, error_type) do
    Req.Test.stub(Elastic.APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      cond do
        conn.method == "PUT" ->
          Req.Test.json(conn, %{"acknowledged" => true})

        String.ends_with?(conn.request_path, "/_rollover") ->
          send(test_pid, {:rollover, conn.request_path})
          Req.Test.json(conn, %{"acknowledged" => true, "rolled_over" => true})

        true ->
          lines = body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
          documents = lines |> Enum.drop_every(2)

          items =
            Enum.map(documents, fn document ->
              if document["firezone"]["subject"]["actor_email"] == "poison@example.com" do
                %{
                  "create" => %{
                    "status" => 400,
                    "error" => %{"type" => "#{error_type}", "reason" => "bad field"}
                  }
                }
              else
                %{"create" => %{"status" => 201}}
              end
            end)

          errors = Enum.any?(items, fn item -> item["create"]["status"] != 201 end)
          Req.Test.json(conn, %{"took" => 2, "errors" => errors, "items" => items})
      end
    end)
  end

end
