defmodule Web.Application do
  use Application

  @impl true
  def start(_type, _args) do
    configure_logger()

    _ = OpentelemetryLiveView.setup()
    _ = :opentelemetry_cowboy.setup()
    _ = OpentelemetryPhoenix.setup(adapter: :cowboy2)

    children = [
      Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Web.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Web.Endpoint.config_change(changed, removed)
    :ok
  end

  defp configure_logger do
    if Mix.env() == :prod do
      config = Application.get_env(:domain, :logger_json)
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
end
