defmodule API.Application do
  use Application

  @impl true
  def start(_type, _args) do
    _ = :opentelemetry_cowboy.setup()
    _ = OpentelemetryPhoenix.setup(adapter: :cowboy2)

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

    children = [
      API.Endpoint,
      API.RateLimit
    ]

    opts = [strategy: :one_for_one, name: API.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    API.Endpoint.config_change(changed, removed)
    :ok
  end
end
