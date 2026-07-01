defmodule Portal.TelemetryTest do
  use ExUnit.Case, async: true

  @config %{node_name: "test"}

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

  describe "handle_http_metric/4" do
    test "returns :ok for a routed request" do
      conn = %Plug.Conn{method: "GET", status: 200, request_path: "/users/abc-123"}
      metadata = %{conn: conn, route: "/users/:id"}

      assert :ok =
               Portal.Telemetry.handle_http_metric(
                 [:phoenix, :router_dispatch, :stop],
                 %{duration: 1_000},
                 metadata,
                 @config
               )
    end

    test "falls back to (unrouted) when route metadata is absent" do
      conn = %Plug.Conn{method: "GET", status: 404, request_path: "/unknown-path"}
      metadata = %{conn: conn}

      assert :ok =
               Portal.Telemetry.handle_http_metric(
                 [:phoenix, :router_dispatch, :stop],
                 %{duration: 500},
                 metadata,
                 @config
               )
    end

    test "handles nil conn status" do
      conn = %Plug.Conn{method: "POST", status: nil, request_path: "/sign_in"}
      metadata = %{conn: conn, route: "/sign_in"}

      assert :ok =
               Portal.Telemetry.handle_http_metric(
                 [:phoenix, :router_dispatch, :stop],
                 %{duration: 2_000},
                 metadata,
                 @config
               )
    end

    test "returns :ok for endpoint start" do
      conn = %Plug.Conn{method: "GET", request_path: "/users"}

      assert :ok =
               Portal.Telemetry.handle_http_metric(
                 [:phoenix, :endpoint, :start],
                 %{system_time: System.system_time()},
                 %{conn: conn},
                 @config
               )
    end

    test "returns :ok for endpoint stop" do
      conn = %Plug.Conn{method: "GET", status: 200, request_path: "/users"}

      assert :ok =
               Portal.Telemetry.handle_http_metric(
                 [:phoenix, :endpoint, :stop],
                 %{duration: 1_000},
                 %{conn: conn},
                 @config
               )
    end
  end

  describe "handle_db_metric/4" do
    test "returns :ok for a normal query" do
      assert :ok =
               Portal.Telemetry.handle_db_metric(
                 [:portal, :repo, :query],
                 %{total_time: 500_000, query_time: 400_000, queue_time: 100_000},
                 %{},
                 @config
               )
    end

    test "returns :ok when total_time is nil" do
      assert :ok =
               Portal.Telemetry.handle_db_metric(
                 [:portal, :repo, :query],
                 %{total_time: nil},
                 %{},
                 @config
               )
    end

    test "handles replica repo event" do
      assert :ok =
               Portal.Telemetry.handle_db_metric(
                 [:portal, :repo, :replica, :query],
                 %{total_time: 200_000},
                 %{},
                 @config
               )
    end
  end

  describe "handle_liveview_lifecycle_metric/4" do
    test "returns :ok for a LiveView mount" do
      socket = %{view: PortalWeb.SignInLive}

      assert :ok =
               Portal.Telemetry.handle_liveview_lifecycle_metric(
                 [:phoenix, :live_view, :mount, :stop],
                 %{duration: 5_000},
                 %{socket: socket, params: %{}, session: %{}, uri: "https://example.com"},
                 @config
               )
    end

    test "returns :ok for handle_params" do
      socket = %{view: PortalWeb.SignInLive}

      assert :ok =
               Portal.Telemetry.handle_liveview_lifecycle_metric(
                 [:phoenix, :live_view, :handle_params, :stop],
                 %{duration: 1_000},
                 %{socket: socket, params: %{}, uri: "https://example.com"},
                 @config
               )
    end
  end

  describe "handle_liveview_event_metric/4" do
    test "returns :ok for a LiveView handle_event" do
      socket = %{view: PortalWeb.SignInLive}

      assert :ok =
               Portal.Telemetry.handle_liveview_event_metric(
                 [:phoenix, :live_view, :handle_event, :stop],
                 %{duration: 2_000},
                 %{socket: socket, event: "save", params: %{}},
                 @config
               )
    end

    test "returns :ok for a LiveComponent handle_event" do
      assert :ok =
               Portal.Telemetry.handle_liveview_event_metric(
                 [:phoenix, :live_component, :handle_event, :stop],
                 %{duration: 1_500},
                 %{component: PortalWeb.Components.ResourceForm, event: "save", params: %{}},
                 @config
               )
    end
  end

  describe "handle_channel_metric/4" do
    test "returns :ok for a channel join" do
      socket = %{channel: PortalAPI.Client.Channel, transport: :websocket}

      assert :ok =
               Portal.Telemetry.handle_channel_metric(
                 [:phoenix, :channel_joined],
                 %{duration: 5_000},
                 %{socket: socket, result: :ok, params: %{}},
                 @config
               )
    end

    test "returns :ok for a channel message" do
      socket = %{channel: PortalAPI.Client.Channel, transport: :websocket}

      assert :ok =
               Portal.Telemetry.handle_channel_metric(
                 [:phoenix, :channel_handled_in],
                 %{duration: 1_000},
                 %{socket: socket, event: "update_resource", params: %{}, ref: "1"},
                 @config
               )
    end
  end

  defp metric_names do
    Enum.map(Portal.Telemetry.metrics(), & &1.name)
  end
end
