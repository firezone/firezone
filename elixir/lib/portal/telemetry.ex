defmodule Portal.Telemetry do
  use Supervisor
  import Telemetry.Metrics
  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    register_otel_instruments()

    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    reporter_children =
      if metrics_reporter = Keyword.get(config, :metrics_reporter) do
        [{metrics_reporter, metrics: metrics()}]
      else
        []
      end

    Supervisor.init(children ++ reporter_children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Database Metrics
      distribution("portal.repo.query.total_time", unit: {:native, :millisecond}),
      summary("portal.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("portal.repo.query.query_time", tags: [:query], unit: {:native, :millisecond}),
      summary("portal.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("portal.repo.query.idle_time", unit: {:native, :millisecond}),

      # Phoenix Metrics
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
      Logger.info("Error in emit_beam_health_metrics",
        reason: inspect(error)
      )

      :ok
  end

  @doc """
  Emits garbage collection metrics across all processes.
  """
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
      Logger.info("Error in emit_gc_metrics",
        reason: inspect(error)
      )

      :ok
  end

  @doc """
  Emits scheduler utilization metrics.
  """
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
        0
      end

    :telemetry.execute([:vm, :scheduler_utilization], %{
      total_run_queue: total_run_queue,
      max_run_queue: max_run_queue,
      avg_run_queue: Float.round(avg_run_queue, 2),
      scheduler_count: length(run_queue_lengths)
    })
  rescue
    error ->
      Logger.info("Error in emit_scheduler_metrics",
        reason: inspect(error)
      )

      :ok
  end

  defp register_otel_instruments do
    meter = :opentelemetry_experimental.get_meter()

    # Common attributes for all metrics to enable splitting by node in Azure Monitor
    node_attrs = %{
      "node_name" => System.get_env("NODE_NAME", to_string(node())),
      "node_type" => System.get_env("NODE_TYPE", "unknown")
    }

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
      Logger.info("Failed to register OTEL instruments", reason: inspect(error))
      :ok
  end

  @doc """
  Debug function to manually trigger and inspect all BEAM metrics.
  Usage in IEx: Portal.Telemetry.debug_metrics()
  """
  def debug_metrics do
    IO.puts("=== BEAM Health Metrics Debug ===")

    # Manually emit and capture metrics
    emit_beam_health_metrics()
    emit_gc_metrics()
    emit_scheduler_metrics()

    # Display current system info
    IO.puts("\n--- Process Info ---")

    IO.puts(
      "Processes: #{:erlang.system_info(:process_count)}/#{:erlang.system_info(:process_limit)}"
    )

    IO.puts("\n--- Memory Info (MB) ---")

    :erlang.memory()
    |> Enum.each(fn {key, value} ->
      IO.puts("#{key}: #{Float.round(value / 1024 / 1024, 2)}")
    end)

    IO.puts("\n--- Atom Info ---")
    IO.puts("Atoms: #{:erlang.system_info(:atom_count)}/#{:erlang.system_info(:atom_limit)}")

    IO.puts("\n--- Port Info ---")
    IO.puts("Ports: #{:erlang.system_info(:port_count)}/#{:erlang.system_info(:port_limit)}")

    IO.puts("\n--- ETS Info ---")
    IO.puts("ETS Tables: #{length(:ets.all())}")

    IO.puts("\n--- Run Queue Info ---")
    IO.puts("Total run queue: #{:erlang.statistics(:total_run_queue_lengths)}")

    :ok
  end
end
