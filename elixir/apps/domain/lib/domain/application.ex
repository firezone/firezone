defmodule Domain.Application do
  use Application

  def start(_type, _args) do
    configure_logger()

    # Attach Oban Sentry reporter
    Domain.Telemetry.Reporter.Oban.attach()

    _ = OpentelemetryLoggerMetadata.setup()
    _ = OpentelemetryEcto.setup([:domain, :repo])

    # Can be uncommented when this bug is fixed: https://github.com/open-telemetry/opentelemetry-erlang-contrib/issues/327
    # _ = OpentelemetryFinch.setup()

    Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  def children do
    [
      # Core services
      Domain.Repo,
      Domain.PubSub,

      # Infrastructure services
      # Note: only one of platform adapters will be actually started.
      Domain.GoogleCloudPlatform,
      Domain.Cluster,
      {Oban, Application.fetch_env!(:domain, Oban)},

      # Application
      Domain.Tokens,
      Domain.Auth,
      Domain.Relays,
      Domain.Gateways,
      Domain.Clients,
      Domain.Billing,
      Domain.Mailer,
      Domain.Mailer.RateLimiter,
      Domain.Notifications,
      Domain.ComponentVersions,

      # Observability
      Domain.Telemetry,

      # WAL replication
      replication_child_spec(),
    ]
  end

  defp replication_child_spec do
    {connection_opts, config} =
      Application.fetch_env!(:domain, Domain.Events.ReplicationConnection)
      |> Keyword.pop(:connection_opts)

    init_state = %{
      connection_opts: connection_opts,
      instance: struct(Domain.Events.ReplicationConnection, config)
    }

    %{
      id: Domain.Events.ReplicationConnection,
      start: {Domain.Events.ReplicationConnection, :start_link, [init_state]},
      restart: :transient,
      # Allow up to 240 restarts in 20 minutes - covers duration of a deploy
      max_restarts: 240,
      max_seconds: 1200
    }
  end

  defp configure_logger do
    # Attach Oban to the logger
    Oban.Telemetry.attach_default_logger(encode: false, level: log_level())

    # Configure Logger severity at runtime
    :ok = LoggerJSON.configure_log_level_from_env!("LOG_LEVEL")

    if config = Application.get_env(:logger_json, :config) do
      formatter = LoggerJSON.Formatters.GoogleCloud.new(config)
      :logger.update_handler_config(:default, :formatter, formatter)
    end

    # Configure Sentry to capture Logger messages
    :logger.add_handler(:sentry, Sentry.LoggerHandler, %{
      config: %{
        level: :warning,
        metadata: :all,
        capture_log_messages: true
      }
    })
  end

  defp log_level do
    case System.get_env("LOG_LEVEL") do
      "error" -> :error
      "warn" -> :warn
      "debug" -> :debug
      _ -> :info
    end
  end
end
