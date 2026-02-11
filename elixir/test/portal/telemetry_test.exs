defmodule Portal.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "metrics/0" do
    test "returns a non-empty list of metric definitions" do
      metrics = Portal.Telemetry.metrics()
      assert is_list(metrics)
      assert length(metrics) > 0
    end

    test "includes database metrics" do
      metric_names = metric_names()

      assert [:portal, :repo, :query, :total_time] in metric_names
      assert [:portal, :repo, :query, :decode_time] in metric_names
      assert [:portal, :repo, :query, :query_time] in metric_names
      assert [:portal, :repo, :query, :queue_time] in metric_names
      assert [:portal, :repo, :query, :idle_time] in metric_names
    end

    test "includes phoenix metrics" do
      metric_names = metric_names()

      assert [:phoenix, :endpoint, :start, :system_time] in metric_names
      assert [:phoenix, :endpoint, :stop, :duration] in metric_names
      assert [:phoenix, :router_dispatch, :stop, :duration] in metric_names
      assert [:phoenix, :socket_connected, :duration] in metric_names
      assert [:phoenix, :channel_join, :duration] in metric_names
    end

    test "includes VM metrics" do
      metric_names = metric_names()

      assert [:vm, :memory, :total] in metric_names
      assert [:vm, :total_run_queue_lengths, :total] in metric_names
      assert [:vm, :total_run_queue_lengths, :cpu] in metric_names
      assert [:vm, :total_run_queue_lengths, :io] in metric_names
    end

    test "includes enhanced BEAM health metrics" do
      metric_names = metric_names()

      assert [:vm, :process_count, :total] in metric_names
      assert [:vm, :process_count, :limit] in metric_names
      assert [:vm, :process_count, :utilization_percent] in metric_names
      assert [:vm, :atom_count, :count] in metric_names
      assert [:vm, :atom_count, :limit] in metric_names
      assert [:vm, :port_count, :count] in metric_names
      assert [:vm, :ets, :count] in metric_names
    end

    test "includes detailed memory breakdown metrics" do
      metric_names = metric_names()

      assert [:vm, :memory, :detailed, :processes] in metric_names
      assert [:vm, :memory, :detailed, :system] in metric_names
      assert [:vm, :memory, :detailed, :atom] in metric_names
      assert [:vm, :memory, :detailed, :binary] in metric_names
      assert [:vm, :memory, :detailed, :code] in metric_names
      assert [:vm, :memory, :detailed, :ets] in metric_names
    end

    test "includes scheduler metrics" do
      metric_names = metric_names()

      assert [:vm, :scheduler_utilization, :total_run_queue] in metric_names
      assert [:vm, :scheduler_utilization, :max_run_queue] in metric_names
      assert [:vm, :scheduler_utilization, :avg_run_queue] in metric_names
      assert [:vm, :scheduler_utilization, :scheduler_count] in metric_names
    end

    test "includes application metrics" do
      metric_names = metric_names()

      assert [:portal, :relays, :online_relays_count] in metric_names
      assert [:portal, :cluster, :discovered_nodes_count] in metric_names
    end

    test "includes directory sync metrics" do
      metric_names = metric_names()

      assert [:portal, :directory_sync, :data_fetch_total_time] in metric_names
      assert [:portal, :directory_sync, :db_operations_total_time] in metric_names
      assert [:portal, :directory_sync, :total_time] in metric_names
    end
  end

  describe "emit_beam_health_metrics/0" do
    test "emits process count telemetry" do
      test_pid = self()
      handler_id = "test-beam-process-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:vm, :process_count],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:process_count, measurements})
        end,
        nil
      )

      try do
        Portal.Telemetry.emit_beam_health_metrics()

        assert_receive {:process_count, measurements}
        assert is_integer(measurements.total)
        assert measurements.total > 0
        assert is_integer(measurements.limit)
        assert measurements.limit > measurements.total
        assert is_float(measurements.utilization_percent)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits atom count telemetry" do
      test_pid = self()
      handler_id = "test-beam-atom-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:vm, :atom_count],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:atom_count, measurements})
        end,
        nil
      )

      try do
        Portal.Telemetry.emit_beam_health_metrics()

        assert_receive {:atom_count, measurements}
        assert is_integer(measurements.count)
        assert measurements.count > 0
        assert is_integer(measurements.limit)
        assert is_float(measurements.utilization_percent)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits port count telemetry" do
      test_pid = self()
      handler_id = "test-beam-port-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:vm, :port_count],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:port_count, measurements})
        end,
        nil
      )

      try do
        Portal.Telemetry.emit_beam_health_metrics()

        assert_receive {:port_count, measurements}
        assert is_integer(measurements.count)
        assert is_integer(measurements.limit)
        assert is_float(measurements.utilization_percent)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits ETS count telemetry" do
      test_pid = self()
      handler_id = "test-beam-ets-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:vm, :ets],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:ets, measurements})
        end,
        nil
      )

      try do
        Portal.Telemetry.emit_beam_health_metrics()

        assert_receive {:ets, measurements}
        assert is_integer(measurements.count)
        assert measurements.count > 0
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits detailed memory breakdown telemetry" do
      test_pid = self()
      handler_id = "test-beam-memory-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:vm, :memory, :detailed],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:memory, measurements})
        end,
        nil
      )

      try do
        Portal.Telemetry.emit_beam_health_metrics()

        assert_receive {:memory, measurements}
        assert is_integer(measurements.processes)
        assert is_integer(measurements.system)
        assert is_integer(measurements.atom)
        assert is_integer(measurements.binary)
        assert is_integer(measurements.code)
        assert is_integer(measurements.ets)
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "emit_gc_metrics/0" do
    test "emits garbage collection telemetry" do
      test_pid = self()
      handler_id = "test-gc-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:vm, :gc],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:gc, measurements})
        end,
        nil
      )

      try do
        Portal.Telemetry.emit_gc_metrics()

        assert_receive {:gc, measurements}
        assert is_integer(measurements.collections_count)
        assert measurements.collections_count >= 0
        assert is_integer(measurements.words_reclaimed)
        assert measurements.words_reclaimed >= 0
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "emit_scheduler_metrics/0" do
    test "emits scheduler utilization telemetry" do
      test_pid = self()
      handler_id = "test-scheduler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:vm, :scheduler_utilization],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:scheduler, measurements})
        end,
        nil
      )

      try do
        Portal.Telemetry.emit_scheduler_metrics()

        assert_receive {:scheduler, measurements}
        assert is_integer(measurements.total_run_queue)
        assert measurements.total_run_queue >= 0
        assert is_integer(measurements.max_run_queue)
        assert is_float(measurements.avg_run_queue)
        assert is_integer(measurements.scheduler_count)
        assert measurements.scheduler_count > 0
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "debug_metrics/0" do
    test "prints all BEAM metric sections and returns :ok" do
      output =
        capture_io(fn ->
          assert Portal.Telemetry.debug_metrics() == :ok
        end)

      assert output =~ "=== BEAM Health Metrics Debug ==="
      assert output =~ "--- Process Info ---"
      assert output =~ "Processes:"
      assert output =~ "--- Memory Info (MB) ---"
      assert output =~ "total:"
      assert output =~ "--- Atom Info ---"
      assert output =~ "Atoms:"
      assert output =~ "--- Port Info ---"
      assert output =~ "Ports:"
      assert output =~ "--- ETS Info ---"
      assert output =~ "ETS Tables:"
      assert output =~ "--- Run Queue Info ---"
      assert output =~ "Total run queue:"
    end
  end

  defp metric_names do
    Enum.map(Portal.Telemetry.metrics(), & &1.name)
  end
end
