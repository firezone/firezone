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

  # Gracefully shut down services that have conflicting start/stop ordering
  # requirements before the supervision tree tears down.
  #
  # prep_stop/1 runs while the full supervision tree is still alive, so each
  # step below executes with all remaining services fully operational.
  #
  # Order matters:
  #
  #   1. Portal.Cluster — broadcast goodbye while DB and PubSub are healthy.
  #      Other nodes receive the goodbye, disconnect immediately, and clean up
  #      our Presence entries via :nodedown — no cross-node CRDT merge tasks
  #      needed, which avoids the Phoenix.Presence FunctionClauseError on
  #      remote nodes when merge tasks time out.
  #
  #   2. Endpoints — kill all channel processes. Presence receives the flood of
  #      EXIT messages and processes them with a fully operational PubSub and
  #      Repo (they're still alive at positions 1-4 in the children list).
  #
  #   3. PortalAPI.RateLimit — destroy the Hammer ETS table only after all
  #      endpoint request processing has stopped, preventing "unknown table"
  #      errors from lingering channel processes.
  @impl true
  def prep_stop(state) do
    _ = Supervisor.terminate_child(__MODULE__.Supervisor, Portal.Cluster)
    _ = Supervisor.terminate_child(__MODULE__.Supervisor, PortalWeb.Endpoint)
    _ = Supervisor.terminate_child(__MODULE__.Supervisor, PortalAPI.Endpoint)
    _ = Supervisor.terminate_child(__MODULE__.Supervisor, PortalAPI.RateLimit)

    state
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
      Portal.Cluster,

      # Application services
      Portal.Presence,
      Portal.Mailer.RateLimiter,
      Portal.ComponentVersions,
      # Health check server (always enabled)
      Portal.Health,

      # Web and API apps are always started to allow VerifiedRoutes to work
      PortalWeb.Endpoint,
      PortalAPI.Endpoint
    ] ++ client_session_buffer() ++ rate_limit() ++ telemetry() ++ oban() ++ replication()
  end

  defp configure_logger do
    # Attach Oban to the logger
    Oban.Telemetry.attach_default_logger(encode: false, level: log_level())

    # Configure Logger severity at runtime
    :ok = LoggerJSON.configure_log_level_from_env!("LOG_LEVEL")

    config = Application.get_env(:logger_json, :config)

    if not is_nil(config) do
      formatter = LoggerJSON.Formatters.Basic.new(config)
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

  defp client_session_buffer do
    config = Portal.Config.get_env(:portal, Portal.ClientSession.Buffer, [])

    if Keyword.get(config, :enabled, true) do
      [Portal.ClientSession.Buffer]
    else
      []
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

  defp rate_limit do
    case Portal.Config.get_env(:portal, :node_type, "portal") do
      type when type in ["api", "portal"] -> [PortalAPI.RateLimit]
      _ -> []
    end
  end

  defp verify_geolix_databases do
    # Geolix loads databases asynchronously via handle_continue, so they may
    # not be ready by the time Portal.Application.start/2 runs. Wait for the
    # async load to finish before proceeding with supervision tree startup.
    for %{id: id, source: source} <- Portal.Config.get_env(:geolix, :databases, []) do
      await_geolix_database(id, source, _retries = 30)
    end
  end

  defp await_geolix_database(id, source, 0) do
    Logger.error("Geolix database #{inspect(id)} failed to load from #{source}")
  end

  defp await_geolix_database(id, source, retries) do
    case Geolix.metadata(where: id) do
      nil ->
        Process.sleep(1000)
        await_geolix_database(id, source, retries - 1)

      _metadata ->
        :ok
    end
  end
end
