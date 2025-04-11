defmodule Domain.Application do
  use Application

  def start(_type, _args) do
    # Configure Logger severity at runtime
    :ok = LoggerJSON.configure_log_level_from_env!("LOG_LEVEL")

    _ = OpentelemetryLoggerMetadata.setup()
    _ = OpentelemetryEcto.setup([:domain, :repo])

    formatter =
      LoggerJSON.Formatters.GoogleCloud.new(
        metadata: {:all_except, [:socket, :conn]},
        redactors: [
          {LoggerJSON.Redactors.RedactKeys, secret_keys}
        ]
      )

    :logger.update_handler_config(:default, :formatter, formatter)

    # Configure Sentry to capture Logger messages
    :logger.add_handler(:sentry, Sentry.LoggerHandler, %{
      config: %{
        level: :warning,
        metadata: :all,
        capture_log_messages: true
      }
    })

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
      Domain.Telemetry
    ]
  end
end
