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

      # Application
      Domain.Presence,
      Domain.Billing,
      Domain.Mailer,
      Domain.Mailer.RateLimiter,
      Domain.ComponentVersions
    ] ++ telemetry() ++ oban() ++ replication()
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

  defp telemetry do
    config = Application.fetch_env!(:domain, Domain.Telemetry)

    if config[:enabled] do
      [Domain.Telemetry]
    else
      []
    end
  end

  defp oban do
    [{Oban, Application.fetch_env!(:domain, Oban)}]
  end

  defp replication do
    connection_modules = [
      Domain.Changes.ReplicationConnection,
      Domain.ChangeLogs.ReplicationConnection
    ]

    # Filter out disabled replication connections
    Enum.reduce(connection_modules, [], fn module, enabled ->
      config = Application.fetch_env!(:domain, module)

      if config[:enabled] do
        spec = %{
          id: module,
          start: {Domain.Replication.Manager, :start_link, [module, []]}
        }

        [spec | enabled]
      else
        enabled
      end
    end)
  end
end
