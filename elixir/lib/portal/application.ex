defmodule Portal.Application do
  use Application

  require Logger

  @expected_client_error_filter :portal_relevel_expected_client_errors

  @impl true
  def start(_type, _args) do
    configure_logger()
    verify_geolix_databases()

    # Attach Oban Sentry reporter
    Portal.Telemetry.Reporter.Oban.attach()

    # OpenTelemetry setup
    :ok = OpentelemetryLoggerMetadata.setup()
    :ok = OpentelemetryEcto.setup([:portal, :repo])
    :ok = OpentelemetryEcto.setup([:portal, :repo, :web])
    :ok = OpentelemetryEcto.setup([:portal, :repo, :api])
    :ok = OpentelemetryEcto.setup([:portal, :repo, :job])
    :ok = Portal.Telemetry.OtelBandit.setup()
    :ok = OpentelemetryPhoenix.setup(adapter: :bandit)
    :ok = OpentelemetryOban.setup()

    Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  @impl true
  def stop(_state) do
    # Remove the Sentry logger handler before Sentry.Supervisor terminates
    # to avoid noproc errors during shutdown
    _ = :logger.remove_handler(:sentry)
    _ = :logger.remove_primary_filter(@expected_client_error_filter)
    :ok
  end

  defp children do
    # Must start before the repos: they may fetch cached Entra access tokens
    # when connecting with DATABASE_ENTRA_AUTH enabled.
    base_children = token_caches() ++ [
      # Core services
      Portal.Repo,
      # Isolated connection pools (web/api/job/poller)
      Portal.Repo.Web,
      Portal.Repo.Api,
      Portal.Repo.Job,
      Portal.Repo.Poller,
      {Task.Supervisor, name: Portal.Analytics.TaskSupervisor},
      # Default pg scope for distributed process discovery (used by replication)
      %{id: :pg, start: {:pg, :start_link, []}},
      # Named pg scope for Portal.PG, isolated so a crash here does not affect replication
      %{id: Portal.PG, start: {:pg, :start_link, [Portal.PG]}},
      Portal.PubSub,

      # Application services
      Portal.Presence,
      Portal.Mailer.RateLimiter,
      Portal.ComponentVersions,
      Portal.ClockDriftAlarm,
      OpenIDConnect.Document.Cache
    ]

    endpoint_children = [
      # Builds the MCP tool table from the API spec; must be ready before the
      # API endpoint starts serving /mcp.
      PortalAPI.MCP.Tools,
      # Give Phoenix socket drain enough time to gracefully close channel topics
      # before transports are force-terminated.
      {PortalWeb.Endpoint, shutdown: 40_000},
      {PortalAPI.Endpoint, shutdown: 40_000},
      {PortalOps.Endpoint, shutdown: 40_000},
      # The public listener stops first during reverse-order shutdown, before
      # the endpoints it dispatches into begin draining.
      {Portal.Endpoint, shutdown: 40_000}
    ]

    # Child order is chosen to make reverse-order shutdown graceful:
    # 1) Portal.Cluster sends goodbye while DB/PubSub are healthy.
    # 2) Replication slot pollers stop while BEAM is still fully alive.
    # 3) Endpoints drain and terminate channels while Presence/PubSub/Repo are alive.
    # 4) Portal{API,Web}.RateLimit stops after endpoint traffic has ceased.
    base_children ++
      client_session_queue() ++
      gateway_session_queue() ++
      policy_authorization_queue() ++
      revocation_endpoint_queue() ++
      rate_limit() ++
      telemetry() ++ oban() ++ endpoint_children ++ replication() ++ [Portal.Cluster]
  end

  defp configure_logger do
    # Bandit and Thousand Island report some routine client disconnects, timeouts,
    # and malformed requests as errors. Relevel those known client-side events to
    # info before they reach stdout (and Azure) or the Sentry handler.
    case :logger.add_primary_filter(
           @expected_client_error_filter,
           {&Portal.LoggerFilters.relevel_expected_client_errors/2, nil}
         ) do
      :ok -> :ok
      {:error, {:already_exist, @expected_client_error_filter}} -> :ok
    end

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

  defp client_session_queue do
    queue_child(:client_session_queue, PortalAPI.Client.Socket.client_session_queue_opts())
  end

  defp gateway_session_queue do
    queue_child(:gateway_session_queue, PortalAPI.Gateway.Socket.gateway_session_queue_opts())
  end

  defp policy_authorization_queue do
    queue_child(
      :policy_authorization_queue,
      PortalAPI.Client.Channel.policy_authorization_queue_opts()
    )
  end

  defp revocation_endpoint_queue do
    queue_child(
      :revocation_endpoint_queue,
      PortalAPI.Client.DeviceTrust.revocation_endpoint_queue_opts()
    )
  end

  defp queue_child(config_key, opts) do
    config = Portal.Config.get_env(:portal, config_key, [])

    if Keyword.get(config, :enabled, true) do
      [{Portal.Queue, opts}]
    else
      []
    end
  end

  defp token_caches do
    config = Application.fetch_env!(:portal, Portal.TokenCache)

    if config[:enabled] do
      [
        token_cache(Portal.Azure.TokenCache),
        token_cache(Portal.Google.TokenCache)
      ]
    else
      []
    end
  end

  defp token_cache(name) do
    %{
      id: name,
      start: {Portal.TokenCache, :start_link, [[name: name]]}
    }
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
    # Skip starting Oban when only the application boot is needed (e.g. CI
    # generating the OpenAPI spec without a Postgres service). Oban 2.22+
    # verifies migrations at supervisor start, which requires a live DB.
    if Portal.Config.env_var_to_config!(:oban_enabled) do
      [{Portal.Oban, Application.fetch_env!(:portal, Oban)}]
    else
      []
    end
  end

  defp replication do
    consumers = [
      Portal.Changes.Consumer,
      Portal.ChangeLogs.Consumer
    ]

    for consumer <- consumers, Application.fetch_env!(:portal, consumer)[:enabled] do
      Supervisor.child_spec({Portal.Replication.SlotPoller, consumer: consumer}, id: consumer)
    end
  end

  defp rate_limit do
    [PortalAPI.RateLimit, PortalWeb.RateLimit]
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
