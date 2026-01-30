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
    :ok = OpentelemetryLoggerMetadata.setup()
    :ok = OpentelemetryEcto.setup([:portal, :repo])
    :ok = OpentelemetryEcto.setup([:portal, :repo, :replica])
    :ok = OpentelemetryBandit.setup()
    :ok = OpentelemetryPhoenix.setup(adapter: :bandit)
    :ok = OpentelemetryOban.setup()

    Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  @impl true
  def prep_stop(state) do
    # Stop database pool supervisors entirely before the supervision tree shuts down.
    #
    # Previously we used Ecto.Adapters.SQL.disconnect_all/2, but that only disconnects
    # connections while leaving the pool supervisor alive. DBConnection's default behavior
    # is to reconnect when connections are lost, which causes SCRAM authentication attempts
    # after the :postgrex application has stopped (killing Postgrex.SCRAM.LockedCache).
    #
    # By stopping the pool supervisors entirely, we prevent any reconnection attempts
    # during the shutdown window.
    Logger.info("Stopping database pools for graceful shutdown")

    stop_timeout = :timer.seconds(5)
    stop_process(Portal.Repo, stop_timeout)
    stop_process(Portal.Repo.Replica, stop_timeout)

    # Note: Replication connections are managed by Portal.Replication.Manager which
    # handles shutdown gracefully via its terminate/2 callback, sending :shutdown
    # to the Postgrex.ReplicationConnection which disconnects cleanly.

    state
  end

  defp stop_process(name, timeout) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid, :shutdown, timeout)
        catch
          :exit, _ -> :ok
        end
    end
  end

  @impl true
  def stop(_state) do
    # Remove the Sentry logger handler before Sentry.Supervisor terminates
    # to avoid noproc errors during shutdown
    _ = :logger.remove_handler(:sentry)
    :ok
  end

  defp children do
    [
      # Core services
      Portal.Repo,
      Portal.Repo.Replica,
      # Default pg scope for distributed process discovery (used by replication)
      %{id: :pg, start: {:pg, :start_link, []}},
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

    config = Application.get_env(:logger_json, :config)
    platform_adapter = Application.get_env(:portal, :platform_adapter)

    if not is_nil(config) do
      formatter =
        if platform_adapter == Portal.GoogleCloudPlatform do
          LoggerJSON.Formatters.GoogleCloud.new(config)
        else
          LoggerJSON.Formatters.Basic.new(config)
        end

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
    # Geolix loads databases asynchronously via handle_continue, so they may
    # not be ready by the time Portal.Application.start/2 runs. Wait for the
    # async load to finish before proceeding with supervision tree startup.
    for %{id: id, source: source} <- Portal.Config.get_env(:geolix, :databases, []) do
      await_geolix_database(id, source, _retries = 50)
    end
  end

  defp await_geolix_database(id, source, 0) do
    Logger.error("Geolix database #{inspect(id)} failed to load from #{source}")
  end

  defp await_geolix_database(id, source, retries) do
    case Geolix.metadata(where: id) do
      nil ->
        Process.sleep(100)
        await_geolix_database(id, source, retries - 1)

      _metadata ->
        :ok
    end
  end
end
