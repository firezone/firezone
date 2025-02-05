defmodule API.Application do
  use Application

  @impl true
  def start(_type, _args) do
    _ = :opentelemetry_cowboy.setup()
    _ = OpentelemetryPhoenix.setup(adapter: :cowboy2)

    children = [
      API.Endpoint
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
