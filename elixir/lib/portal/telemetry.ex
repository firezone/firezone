defmodule Portal.Telemetry do
  use Supervisor
  import Telemetry.Metrics
  require Logger

  @metric_groups %{
    http: %{
      handler_id: "portal-http-metrics",
      events: [
        [:phoenix, :router_dispatch, :stop],
        [:phoenix, :endpoint, :start],
        [:phoenix, :endpoint, :stop]
      ]
    },
    db: %{
      handler_id: "portal-db-metrics",
      events: [
        [:portal, :repo, :query],
        [:portal, :repo, :replica, :query],
        [:portal, :repo, :web, :query],
        [:portal, :repo, :api, :query],
        [:portal, :repo, :replica, :web, :query],
        [:portal, :repo, :replica, :api, :query]
      ]
    },
    liveview_lifecycle: %{
      handler_id: "portal-liveview-lifecycle-metrics",
      events: [
        [:phoenix, :live_view, :mount, :stop],
        [:phoenix, :live_view, :handle_params, :stop]
      ]
    },
    liveview_events: %{
      handler_id: "portal-liveview-event-metrics",
      events: [
        [:phoenix, :live_view, :handle_event, :stop],
        [:phoenix, :live_component, :handle_event, :stop]
      ]
    },
    channels: %{
      handler_id: "portal-channel-metrics",
      events: [
        [:phoenix, :channel_joined],
        [:phoenix, :channel_handled_in]
      ]
    }
  }

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    Enum.each(@metric_groups, fn {_group, %{handler_id: id}} -> :telemetry.detach(id) end)

    children =
      if Keyword.get(config, :enabled, true) do
        register_otel_instruments()
        Enum.each(Map.keys(@metric_groups), &enable_metrics/1)
        build_children(config)
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children(config) do
    [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ] ++
      reporter_child(config) ++
      dev_aggregator_child(config)
  end

  defp reporter_child(config) do
    case Keyword.get(config, :metrics_reporter) do
      nil -> []
      reporter -> [{reporter, metrics: metrics()}]
    end
  end

  defp dev_aggregator_child(config) do
    if Keyword.get(config, :metrics_debug) do
      [Portal.Telemetry.DevAggregator]
    else
      []
    end
  end

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Database Metrics
      distribution("portal.repo.query.total_time", unit: {:native, :millisecond}),
      summary("portal.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("portal.repo.query.query_time", tags: [:query], unit: {:native, :millisecond}),
      summary("portal.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("portal.repo.query.idle_time", unit: {:native, :millisecond}),

      # Phoenix Metrics
      counter("phoenix.router_dispatch.stop",
        tags: [:route],
        description: "HTTP request count by route"
      ),
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_join.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Basic VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Enhanced BEAM Health Metrics
      last_value("vm.process_count.total"),
      last_value("vm.process_count.limit"),
      last_value("vm.process_count.utilization_percent"),
      last_value("vm.atom_count.count"),
      last_value("vm.atom_count.limit"),
      last_value("vm.atom_count.utilization_percent"),
      last_value("vm.port_count.count"),
      last_value("vm.port_count.limit"),
      last_value("vm.port_count.utilization_percent"),
      last_value("vm.ets.count"),

      # Detailed Memory Breakdown
      last_value("vm.memory.detailed.processes", unit: {:byte, :kilobyte}),
      last_value("vm.memory.detailed.system", unit: {:byte, :kilobyte}),
      last_value("vm.memory.detailed.atom", unit: {:byte, :kilobyte}),
      last_value("vm.memory.detailed.binary", unit: {:byte, :kilobyte}),
      last_value("vm.memory.detailed.code", unit: {:byte, :kilobyte}),
      last_value("vm.memory.detailed.ets", unit: {:byte, :kilobyte}),

      # Garbage Collection Metrics
      summary("vm.gc.collections_count"),
      summary("vm.gc.words_reclaimed"),

      # Scheduler/Run Queue Metrics
      last_value("vm.scheduler_utilization.total_run_queue"),
      last_value("vm.scheduler_utilization.max_run_queue"),
      last_value("vm.scheduler_utilization.avg_run_queue"),
      last_value("vm.scheduler_utilization.scheduler_count"),

      # Application metrics
      last_value("portal.relays.online_relays_count"),
      last_value("portal.cluster.discovered_nodes_count"),

      ## Directory Syncs
      summary("portal.directory_sync.data_fetch_total_time",
        tags: [:account_id, :provider_id, :provider_adapter]
      ),
      summary("portal.directory_sync.db_operations_total_time",
        tags: [:account_id, :provider_id, :provider_adapter]
      ),
      distribution("portal.directory_sync.total_time",
        tags: [:account_id, :provider_id, :provider_adapter]
      )
    ]
  end

  defp periodic_measurements do
    [
      {Portal.Presence.Relays, :send_metrics, []},
      # Enhanced BEAM measurements
      {__MODULE__, :emit_beam_health_metrics, []},
      {__MODULE__, :emit_gc_metrics, []},
      {__MODULE__, :emit_scheduler_metrics, []}
    ]
  end

  @doc """
  Emits comprehensive BEAM health metrics including process counts,
  atom usage, port usage, ETS tables, and detailed memory breakdown.
  """
  @spec emit_beam_health_metrics() :: :ok
  def emit_beam_health_metrics do
    # Process counts and utilization
    process_count = :erlang.system_info(:process_count)
    process_limit = :erlang.system_info(:process_limit)
    process_utilization = Float.round(process_count / process_limit * 100, 2)

    :telemetry.execute([:vm, :process_count], %{
      total: process_count,
      limit: process_limit,
      utilization_percent: process_utilization
    })

    # Atom table usage
    atom_count = :erlang.system_info(:atom_count)
    atom_limit = :erlang.system_info(:atom_limit)
    atom_utilization = Float.round(atom_count / atom_limit * 100, 2)

    :telemetry.execute([:vm, :atom_count], %{
      count: atom_count,
      limit: atom_limit,
      utilization_percent: atom_utilization
    })

    # Port usage
    port_count = :erlang.system_info(:port_count)
    port_limit = :erlang.system_info(:port_limit)
    port_utilization = Float.round(port_count / port_limit * 100, 2)

    :telemetry.execute([:vm, :port_count], %{
      count: port_count,
      limit: port_limit,
      utilization_percent: port_utilization
    })

    # ETS table count
    ets_count = length(:ets.all())
    :telemetry.execute([:vm, :ets], %{count: ets_count})

    # Detailed memory breakdown
    memory_info = :erlang.memory() |> Enum.into(%{})
    :telemetry.execute([:vm, :memory, :detailed], memory_info)
  rescue
    error ->
      Logger.error("Error in emit_beam_health_metrics",
        reason: inspect(error)
      )

      :ok
  end

  @doc """
  Emits garbage collection metrics across all processes.
  """
  @spec emit_gc_metrics() :: :ok
  def emit_gc_metrics do
    gc_info = :erlang.statistics(:garbage_collection)
    {collections, words_reclaimed, _} = gc_info

    :telemetry.execute([:vm, :gc], %{
      collections_count: collections,
      words_reclaimed: words_reclaimed,
      # We'll skip GC time for now as it's complex to measure accurately
      time: 0
    })
  rescue
    error ->
      Logger.error("Error in emit_gc_metrics",
        reason: inspect(error)
      )

      :ok
  end

  @doc """
  Emits scheduler utilization metrics.
  """
  @spec emit_scheduler_metrics() :: :ok
  def emit_scheduler_metrics do
    # Get total run queue length (single integer)
    total_run_queue = :erlang.statistics(:total_run_queue_lengths)

    # Get run queue lengths per scheduler (list of integers)
    run_queue_lengths = :erlang.statistics(:run_queue_lengths)

    max_run_queue = Enum.max(run_queue_lengths, fn -> 0 end)

    avg_run_queue =
      if run_queue_lengths != [] do
        Enum.sum(run_queue_lengths) / length(run_queue_lengths)
      else
        0.0
      end

    :telemetry.execute([:vm, :scheduler_utilization], %{
      total_run_queue: total_run_queue,
      max_run_queue: max_run_queue,
      avg_run_queue: Float.round(avg_run_queue, 2),
      scheduler_count: length(run_queue_lengths)
    })
  rescue
    error ->
      Logger.error("Error in emit_scheduler_metrics",
        reason: inspect(error)
      )

      :ok
  end

  defp register_otel_instruments do
    meter = :opentelemetry_experimental.get_meter()
    node_attrs = %{"node_name" => System.get_env("NODE_NAME", to_string(node()))}
    register_vm_instruments(meter, node_attrs)
    register_application_instruments(meter)
  end

  defp register_vm_instruments(meter, node_attrs) do
    # Observable gauges for BEAM health
    :otel_meter.create_observable_gauge(
      meter,
      :"vm.process_count",
      fn _args ->
        count = :erlang.system_info(:process_count)
        limit = :erlang.system_info(:process_limit)
        utilization = Float.round(count / limit * 100, 2)

        [
          {count, Map.put(node_attrs, "type", "total")},
          {limit, Map.put(node_attrs, "type", "limit")},
          {utilization, Map.put(node_attrs, "type", "utilization_percent")}
        ]
      end,
      [],
      %{description: "BEAM process count, limit, and utilization"}
    )

    :otel_meter.create_observable_gauge(
      meter,
      :"vm.atom_count",
      fn _args ->
        count = :erlang.system_info(:atom_count)
        limit = :erlang.system_info(:atom_limit)
        utilization = Float.round(count / limit * 100, 2)

        [
          {count, Map.put(node_attrs, "type", "count")},
          {limit, Map.put(node_attrs, "type", "limit")},
          {utilization, Map.put(node_attrs, "type", "utilization_percent")}
        ]
      end,
      [],
      %{description: "BEAM atom count, limit, and utilization"}
    )

    :otel_meter.create_observable_gauge(
      meter,
      :"vm.port_count",
      fn _args ->
        count = :erlang.system_info(:port_count)
        limit = :erlang.system_info(:port_limit)
        utilization = Float.round(count / limit * 100, 2)

        [
          {count, Map.put(node_attrs, "type", "count")},
          {limit, Map.put(node_attrs, "type", "limit")},
          {utilization, Map.put(node_attrs, "type", "utilization_percent")}
        ]
      end,
      [],
      %{description: "BEAM port count, limit, and utilization"}
    )

    :otel_meter.create_observable_gauge(
      meter,
      :"vm.ets.count",
      fn _args ->
        [{length(:ets.all()), node_attrs}]
      end,
      [],
      %{description: "Number of ETS tables"}
    )

    :otel_meter.create_observable_gauge(
      meter,
      :"vm.memory",
      fn _args ->
        memory = :erlang.memory() |> Enum.into(%{})

        [
          {memory[:processes], Map.put(node_attrs, "type", "processes")},
          {memory[:system], Map.put(node_attrs, "type", "system")},
          {memory[:atom], Map.put(node_attrs, "type", "atom")},
          {memory[:binary], Map.put(node_attrs, "type", "binary")},
          {memory[:code], Map.put(node_attrs, "type", "code")},
          {memory[:ets], Map.put(node_attrs, "type", "ets")}
        ]
      end,
      [],
      %{description: "BEAM memory usage in bytes", unit: :By}
    )

    :otel_meter.create_observable_gauge(
      meter,
      :"vm.scheduler_utilization",
      fn _args ->
        total_run_queue = :erlang.statistics(:total_run_queue_lengths)
        run_queue_lengths = :erlang.statistics(:run_queue_lengths)
        max_run_queue = Enum.max(run_queue_lengths, fn -> 0 end)

        avg_run_queue =
          if run_queue_lengths != [] do
            Float.round(Enum.sum(run_queue_lengths) / length(run_queue_lengths), 2)
          else
            0.0
          end

        [
          {total_run_queue, Map.put(node_attrs, "type", "total_run_queue")},
          {max_run_queue, Map.put(node_attrs, "type", "max_run_queue")},
          {avg_run_queue, Map.put(node_attrs, "type", "avg_run_queue")},
          {length(run_queue_lengths), Map.put(node_attrs, "type", "scheduler_count")}
        ]
      end,
      [],
      %{description: "BEAM scheduler run queue metrics"}
    )

    # Observable counters for monotonically increasing values
    :otel_meter.create_observable_counter(
      meter,
      :"vm.gc.collections_count",
      fn _args ->
        {collections, _words_reclaimed, _} = :erlang.statistics(:garbage_collection)
        [{collections, node_attrs}]
      end,
      [],
      %{description: "Total number of garbage collections"}
    )

    :otel_meter.create_observable_counter(
      meter,
      :"vm.gc.words_reclaimed",
      fn _args ->
        {_collections, words_reclaimed, _} = :erlang.statistics(:garbage_collection)
        [{words_reclaimed, node_attrs}]
      end,
      [],
      %{description: "Total words reclaimed by garbage collection"}
    )

    :ok
  rescue
    error ->
      Logger.error("Failed to register VM OTel instruments", reason: inspect(error))
  end

  defp register_application_instruments(meter) do
    :otel_meter.create_counter(
      meter,
      :"http.server.requests",
      %{description: "Total HTTP requests by route, method, and status", unit: :"1"}
    )

    :otel_meter.create_histogram(
      meter,
      :"http.server.request.duration",
      %{description: "HTTP request duration by route", unit: :ms}
    )

    :otel_meter.create_updown_counter(
      meter,
      :"http.server.active_requests",
      %{description: "Number of HTTP requests currently being processed"}
    )

    :otel_meter.create_histogram(
      meter,
      :"db.query.duration",
      %{description: "Database query duration", unit: :ms}
    )

    :otel_meter.create_counter(
      meter,
      :"phoenix.live_view.mounts",
      %{description: "Total LiveView mounts", unit: :"1"}
    )

    :otel_meter.create_histogram(
      meter,
      :"phoenix.live_view.mount.duration",
      %{description: "LiveView mount duration", unit: :ms}
    )

    :otel_meter.create_counter(
      meter,
      :"phoenix.live_view.handle_params",
      %{description: "Total LiveView handle_params calls", unit: :"1"}
    )

    :otel_meter.create_histogram(
      meter,
      :"phoenix.live_view.handle_params.duration",
      %{description: "LiveView handle_params duration", unit: :ms}
    )

    :otel_meter.create_counter(
      meter,
      :"phoenix.live_view.handle_events",
      %{description: "Total LiveView handle_event calls", unit: :"1"}
    )

    :otel_meter.create_histogram(
      meter,
      :"phoenix.live_view.handle_event.duration",
      %{description: "LiveView handle_event duration", unit: :ms}
    )

    :otel_meter.create_counter(
      meter,
      :"phoenix.live_component.handle_events",
      %{description: "Total LiveComponent handle_event calls", unit: :"1"}
    )

    :otel_meter.create_histogram(
      meter,
      :"phoenix.live_component.handle_event.duration",
      %{description: "LiveComponent handle_event duration", unit: :ms}
    )

    :otel_meter.create_counter(
      meter,
      :"phoenix.channel.joins",
      %{description: "Total channel join events", unit: :"1"}
    )

    :otel_meter.create_histogram(
      meter,
      :"phoenix.channel.join.duration",
      %{description: "Channel join duration", unit: :ms}
    )

    :otel_meter.create_counter(
      meter,
      :"phoenix.channel.messages",
      %{description: "Total channel messages handled", unit: :"1"}
    )

    :otel_meter.create_histogram(
      meter,
      :"phoenix.channel.message.duration",
      %{description: "Channel message handling duration", unit: :ms}
    )

    :ok
  rescue
    error ->
      Logger.error("Failed to register application OTel instruments", reason: inspect(error))
  end

  @doc false
  @spec handle_http_metric(list(), map(), map(), map()) :: :ok
  def handle_http_metric([:phoenix, :router_dispatch, :stop], measurements, metadata, config) do
    conn = metadata.conn
    route = metadata[:route] || "(unrouted)"

    attrs = %{
      "http.route" => route,
      "http.request.method" => conn.method,
      "http.response.status_code" => to_string(conn.status || 0),
      "http.endpoint" => endpoint_name(conn),
      "node_name" => config.node_name
    }

    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    meter = :opentelemetry_experimental.get_meter()
    ctx = :otel_ctx.get_current()

    :otel_counter.add(ctx, meter, :"http.server.requests", 1, attrs)
    :otel_histogram.record(ctx, meter, :"http.server.request.duration", duration_ms, attrs)
    :ok
  end

  def handle_http_metric([:phoenix, :endpoint, :start], _measurements, metadata, config) do
    conn = metadata.conn

    attrs = %{
      "http.request.method" => conn.method,
      "http.endpoint" => endpoint_name(conn),
      "node_name" => config.node_name
    }

    meter = :opentelemetry_experimental.get_meter()
    :otel_updown_counter.add(:otel_ctx.get_current(), meter, :"http.server.active_requests", 1, attrs)
    :ok
  end

  def handle_http_metric([:phoenix, :endpoint, :stop], _measurements, metadata, config) do
    conn = metadata.conn

    attrs = %{
      "http.request.method" => conn.method,
      "http.endpoint" => endpoint_name(conn),
      "node_name" => config.node_name
    }

    meter = :opentelemetry_experimental.get_meter()
    :otel_updown_counter.add(:otel_ctx.get_current(), meter, :"http.server.active_requests", -1, attrs)
    :ok
  end

  @doc false
  @spec handle_db_metric(list(), map(), map(), map()) :: :ok
  def handle_db_metric(_event, measurements, _metadata, config) do
    case measurements[:total_time] do
      total_time when is_integer(total_time) ->
        duration_ms = System.convert_time_unit(total_time, :native, :millisecond)

        attrs = %{
          "db.system" => "postgresql",
          "node_name" => config.node_name
        }

        meter = :opentelemetry_experimental.get_meter()
        :otel_histogram.record(:otel_ctx.get_current(), meter, :"db.query.duration", duration_ms, attrs)
        :ok

      _ ->
        :ok
    end
  end

  @doc false
  @spec handle_liveview_lifecycle_metric(list(), map(), map(), map()) :: :ok
  def handle_liveview_lifecycle_metric([:phoenix, :live_view, :mount, :stop], measurements, metadata, config) do
    attrs = %{
      "live_view" => inspect(metadata.socket.view),
      "node_name" => config.node_name
    }

    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    meter = :opentelemetry_experimental.get_meter()
    ctx = :otel_ctx.get_current()

    :otel_counter.add(ctx, meter, :"phoenix.live_view.mounts", 1, attrs)
    :otel_histogram.record(ctx, meter, :"phoenix.live_view.mount.duration", duration_ms, attrs)
    :ok
  end

  def handle_liveview_lifecycle_metric(
        [:phoenix, :live_view, :handle_params, :stop],
        measurements,
        metadata,
        config
      ) do
    attrs = %{
      "live_view" => inspect(metadata.socket.view),
      "node_name" => config.node_name
    }

    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    meter = :opentelemetry_experimental.get_meter()
    ctx = :otel_ctx.get_current()

    :otel_counter.add(ctx, meter, :"phoenix.live_view.handle_params", 1, attrs)
    :otel_histogram.record(ctx, meter, :"phoenix.live_view.handle_params.duration", duration_ms, attrs)
    :ok
  end

  @doc false
  @spec handle_liveview_event_metric(list(), map(), map(), map()) :: :ok
  def handle_liveview_event_metric([:phoenix, :live_view, :handle_event, :stop], measurements, metadata, config) do
    attrs = %{
      "live_view" => inspect(metadata.socket.view),
      "event" => metadata.event,
      "node_name" => config.node_name
    }

    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    meter = :opentelemetry_experimental.get_meter()
    ctx = :otel_ctx.get_current()

    :otel_counter.add(ctx, meter, :"phoenix.live_view.handle_events", 1, attrs)
    :otel_histogram.record(ctx, meter, :"phoenix.live_view.handle_event.duration", duration_ms, attrs)
    :ok
  end

  def handle_liveview_event_metric(
        [:phoenix, :live_component, :handle_event, :stop],
        measurements,
        metadata,
        config
      ) do
    attrs = %{
      "component" => inspect(metadata.component),
      "event" => metadata.event,
      "node_name" => config.node_name
    }

    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    meter = :opentelemetry_experimental.get_meter()
    ctx = :otel_ctx.get_current()

    :otel_counter.add(ctx, meter, :"phoenix.live_component.handle_events", 1, attrs)
    :otel_histogram.record(ctx, meter, :"phoenix.live_component.handle_event.duration", duration_ms, attrs)
    :ok
  end

  @doc false
  @spec handle_channel_metric(list(), map(), map(), map()) :: :ok
  def handle_channel_metric([:phoenix, :channel_joined], measurements, metadata, config) do
    socket = metadata.socket

    attrs = %{
      "channel" => inspect(socket.channel),
      "transport" => to_string(socket.transport),
      "node_name" => config.node_name
    }

    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    meter = :opentelemetry_experimental.get_meter()
    ctx = :otel_ctx.get_current()

    :otel_counter.add(ctx, meter, :"phoenix.channel.joins", 1, attrs)
    :otel_histogram.record(ctx, meter, :"phoenix.channel.join.duration", duration_ms, attrs)
    :ok
  end

  def handle_channel_metric([:phoenix, :channel_handled_in], measurements, metadata, config) do
    socket = metadata.socket

    attrs = %{
      "channel" => inspect(socket.channel),
      "event" => metadata.event,
      "transport" => to_string(socket.transport),
      "node_name" => config.node_name
    }

    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    meter = :opentelemetry_experimental.get_meter()
    ctx = :otel_ctx.get_current()

    :otel_counter.add(ctx, meter, :"phoenix.channel.messages", 1, attrs)
    :otel_histogram.record(ctx, meter, :"phoenix.channel.message.duration", duration_ms, attrs)
    :ok
  end

  @spec enable_metrics(atom()) :: :ok | {:error, :already_enabled} | {:error, :unknown_group}
  def enable_metrics(group) do
    case Map.fetch(@metric_groups, group) do
      {:ok, %{handler_id: id, events: events}} ->
        node_name = System.get_env("NODE_NAME", to_string(node()))

        case :telemetry.attach_many(id, events, metric_group_handler(group), %{node_name: node_name}) do
          :ok -> :ok
          {:error, :already_exists} -> {:error, :already_enabled}
        end

      :error ->
        {:error, :unknown_group}
    end
  end

  @spec disable_metrics(atom()) :: :ok | {:error, :unknown_group}
  def disable_metrics(group) do
    case Map.fetch(@metric_groups, group) do
      {:ok, %{handler_id: id}} ->
        :telemetry.detach(id)
        :ok

      :error ->
        {:error, :unknown_group}
    end
  end

  @spec metrics_enabled?(atom()) :: boolean()
  def metrics_enabled?(group) do
    case Map.fetch(@metric_groups, group) do
      {:ok, %{handler_id: id, events: [first_event | _]}} ->
        :telemetry.list_handlers(first_event)
        |> Enum.any?(&(&1.id == id))

      :error ->
        false
    end
  end

  @spec enabled_metrics() :: [atom()]
  def enabled_metrics do
    Enum.filter(Map.keys(@metric_groups), &metrics_enabled?/1)
  end

  defp metric_group_handler(:http), do: &__MODULE__.handle_http_metric/4
  defp metric_group_handler(:db), do: &__MODULE__.handle_db_metric/4
  defp metric_group_handler(:liveview_lifecycle), do: &__MODULE__.handle_liveview_lifecycle_metric/4
  defp metric_group_handler(:liveview_events), do: &__MODULE__.handle_liveview_event_metric/4
  defp metric_group_handler(:channels), do: &__MODULE__.handle_channel_metric/4

  @doc false
  @spec endpoint_name(Plug.Conn.t()) :: String.t()
  def endpoint_name(conn) do
    case Map.get(conn.private, :phoenix_endpoint) do
      PortalWeb.Endpoint -> "web"
      PortalAPI.Endpoint -> "api"
      PortalOps.Endpoint -> "ops"
      nil -> "unknown"
      mod -> mod |> to_string() |> String.replace_prefix("Elixir.", "")
    end
  end
end
