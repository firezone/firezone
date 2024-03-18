defmodule Domain.Telemetry do
  use Supervisor
  import Telemetry.Metrics
  alias Domain.Telemetry

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # We start a /healthz endpoint that is used for liveness probes
      {Bandit, plug: Telemetry.HealthzPlug, scheme: :http, port: 4000},

      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Database Metrics
      summary("domain.repo.query.total_time", unit: {:native, :millisecond}),
      summary("domain.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("domain.repo.query.query_time", unit: {:native, :millisecond}),
      summary("domain.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("domain.repo.query.idle_time", unit: {:native, :millisecond}),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {Web, :count_users, []}
    ]
  end
end
