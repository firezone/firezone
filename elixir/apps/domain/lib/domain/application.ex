defmodule Domain.Application do
  use Application
  require Logger

  def start(_type, _args) do
    configure_logger()

    # Catch sigterm to allow graceful shutdown
    System.trap_signal(:sigterm, fn ->
      Logger.info("Received SIGTERM, initiating graceful shutdown...")
      System.stop(0)
    end)

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
    ] ++ oban() ++ replication()
  end

  def stop(_state) do
    Logger.info("Application shutting down...")

    # Perform graceful shutdown
    graceful_shutdown()

    Logger.info("Application shutdown complete")
    :ok
  end

  defp graceful_shutdown do
    # 1. Stop accepting new work
    stop_oban_queues()

    # 2. Wait for current jobs to complete
    wait_for_oban_jobs()

    # 3. Stop replication connections gracefully
    stop_replication_connections()

    # 4. Shut down Presence tracking
    shutdown_presence()
    # Note: Repo and PubSub will be stopped automatically by the supervisor

    Process.sleep(1000) # Give some time for the shutdown to complete
  end

  defp shutdown_presence do
    Phoenix.Tracker.graceful_permdown(Domain.Clients.Presence)
    Phoenix.Tracker.graceful_permdown(Domain.Gateways.Presence)
    Phoenix.Tracker.graceful_permdown(Domain.Relays.Presence)
  end

  defp stop_oban_queues do
    Logger.info("Stopping Oban queues...")

    # Pause all queues to stop accepting new jobs
    case Process.whereis(Oban) do
      nil ->
        :ok

      _pid ->
        try do
          Oban.pause_all_queues()
          Logger.info("Oban queues paused")
        rescue
          e -> Logger.warning("Failed to pause Oban queues: #{inspect(e)}")
        end
    end
  end

  defp wait_for_oban_jobs do
    Logger.info("Waiting for Oban jobs to complete...")

    # Wait for running jobs to finish (with timeout)
    # 30 seconds
    max_wait_time = 30_000
    # 1 second
    check_interval = 1_000

    wait_for_jobs_completion(max_wait_time, check_interval)
  end

  defp wait_for_jobs_completion(0, _interval) do
    Logger.warning("Timeout waiting for Oban jobs to complete")
  end

  defp wait_for_jobs_completion(remaining_time, interval) when remaining_time > 0 do
    case get_running_jobs_count() do
      0 ->
        Logger.info("All Oban jobs completed")

      count ->
        Logger.info("#{count} Oban jobs still running, waiting...")
        Process.sleep(interval)
        wait_for_jobs_completion(remaining_time - interval, interval)
    end
  end

  defp get_running_jobs_count do
    try do
      case Process.whereis(Oban) do
        nil ->
          0

        _pid ->
          # Get count of currently executing jobs
          Oban.check_queue(limit: 1000)
          |> Map.get(:running, [])
          |> length()
      end
    rescue
      _ -> 0
    end
  end

  defp stop_replication_connections do
    Logger.info("Stopping replication connections...")

    replication_modules = [
      Domain.Events.ReplicationConnection,
      Domain.ChangeLogs.ReplicationConnection
    ]

    Enum.each(replication_modules, fn module ->
      case :global.whereis_name(module) do
        nil ->
          :ok

        pid ->
          Logger.info("Stopping #{module}...")
          Process.exit(pid, :normal)
      end
    end)
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

  # TODO: Configure Oban workers to only run on domain nodes
  defp oban do
    [{Oban, Application.fetch_env!(:domain, Oban)}]
  end

  defp replication do
    connection_modules = [
      Domain.Events.ReplicationConnection,
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
