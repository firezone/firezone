defmodule Domain.Application do
  use Application

  def start(_type, _args) do
    # Configure Logger severity at runtime
    :ok = LoggerJSON.configure_log_level_from_env!("LOG_LEVEL")

    _ =
      :telemetry.attach(
        "repo-log-handler",
        [:domain, :repo, :query],
        &LoggerJSON.Ecto.telemetry_logging_handler/4,
        :debug
      )

    _ = OpentelemetryEcto.setup([:domain, :repo])
    _ = OpentelemetryFinch.setup()

    Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  def children do
    [
      # Infrastructure services
      Domain.Repo,
      {Phoenix.PubSub, name: Domain.PubSub},

      # Application
      Domain.Auth,
      Domain.Relays,
      Domain.Gateways,
      Domain.Devices,

      # Observability
      # Domain.Telemetry

      # Erlang Clustering
      Domain.Cluster
    ]
  end
end
