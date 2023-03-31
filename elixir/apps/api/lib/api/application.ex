defmodule API.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      API.Telemetry,
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
