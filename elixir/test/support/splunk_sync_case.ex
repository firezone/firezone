defmodule Portal.Splunk.SyncCase do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
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
      alias Portal.Repo
      alias Portal.LogSinkCursor
      alias Portal.SessionLog
      alias Portal.Splunk
      alias Portal.Types.LogId

      setup do
        test_pid = self()

        Req.Test.stub(Splunk.APIClient, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          events = body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
          send(test_pid, {:hec, conn, events})
          Req.Test.json(conn, %{"text" => "Success", "code" => 0})
        end)

        %{account: account_fixture(features: %{log_sinks: true})}
      end

      def close_flow(account, flow_end) do
        from(f in FlowLog,
          where: f.account_id == ^account.id,
          update: [
            set: [
              start_seq: f.seq,
              seq: fragment("nextval('flow_logs_seq_seq')"),
              flow_end: ^flow_end,
              last_packet: ^flow_end,
              outers: ^[
                %FlowLog.Outer{
                  src_ip: "203.0.113.10",
                  src_port: 51_820,
                  dst_ip: "198.51.100.5",
                  dst_port: 51_820
                }
              ],
              rx_packets: 10,
              tx_packets: 12,
              rx_bytes: 1024,
              tx_bytes: 2048
            ]
          ]
        )
        |> Repo.update_all([])
      end

      def get_cursor(sink, stream, phase) do
        Repo.get_by(LogSinkCursor,
          account_id: sink.account_id,
          log_sink_id: sink.id,
          stream: stream,
          phase: phase
        )
      end

      def reload_sink(sink) do
        Repo.get_by!(Splunk.LogSink, account_id: sink.account_id, id: sink.id)
      end
    end
  end
end
