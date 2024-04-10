defmodule Domain.Telemetry do
  use Supervisor
  import Telemetry.Metrics
  alias Domain.Telemetry

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    config = Domain.Config.fetch_env!(:domain, __MODULE__)

    children = [
      # We start a /healthz endpoint that is used for liveness probes
      {Bandit, plug: Telemetry.HealthzPlug, scheme: :http, port: 4000},

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
      distribution("domain.repo.query.total_time", unit: {:native, :millisecond}),
      summary("domain.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("domain.repo.query.query_time", tags: [:query], unit: {:native, :millisecond}),
      summary("domain.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("domain.repo.query.idle_time", unit: {:native, :millisecond}),

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

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Application metrics
      last_value("domain.relays.online_relays_count"),
      last_value("domain.metrics.discovered_nodes_count")
    ]
  end

  defp periodic_measurements do
    [
      {Domain.Relays, :send_metrics, []}
    ]
  end
end
