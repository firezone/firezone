defmodule Portal.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    configure_logger()
    verify_geolix_databases()

    # Attach Oban Sentry reporter
    Portal.Telemetry.Reporter.Oban.attach()

    # OpenTelemetry setup
    _ = OpentelemetryLoggerMetadata.setup()
    _ = OpentelemetryEcto.setup([:portal, :repo])
    _ = OpentelemetryBandit.setup()
    _ = OpentelemetryPhoenix.setup(adapter: :bandit)

    Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  defp children do
    [
      # Core services
      Portal.Repo,
      Portal.PubSub,

      # Infrastructure services
      # Note: only one of platform adapters will be actually started.
      Portal.GoogleCloudPlatform,
      Portal.Cluster,

      # Application services
      Portal.Presence,
      Portal.Mailer.RateLimiter,
      Portal.ComponentVersions,

      # Health check server (always enabled)
      Portal.Health,

      # Web and API apps are always started to allow VerifiedRoutes to work
      PortalWeb.Endpoint,
      PortalAPI.Endpoint,
      PortalAPI.RateLimit
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
    config = Application.fetch_env!(:portal, Portal.Telemetry)

    if config[:enabled] do
      [Portal.Telemetry]
    else
      []
    end
  end

  defp oban do
    [{Oban, Application.fetch_env!(:portal, Oban)}]
  end

  defp replication do
    connection_modules = [
      Portal.Changes.ReplicationConnection,
      Portal.ChangeLogs.ReplicationConnection
    ]

    # Filter out disabled replication connections
    Enum.reduce(connection_modules, [], fn module, enabled ->
      config = Application.fetch_env!(:portal, module)

      if config[:enabled] do
        spec = %{
          id: module,
          start: {Portal.Replication.Manager, :start_link, [module, []]}
        }

        [spec | enabled]
      else
        enabled
      end
    end)
  end

  defp verify_geolix_databases do
    for %{id: id, source: source} <- Portal.Config.get_env(:geolix, :databases, []) do
      case Geolix.metadata(where: id) do
        nil ->
          Logger.error("Geolix database #{inspect(id)} failed to load from #{source}")

        _metadata ->
          :ok
      end
    end
  end
end
