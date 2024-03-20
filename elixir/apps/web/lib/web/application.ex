defmodule Web.Application do
  use Application

  @impl true
  def start(_type, _args) do
    _ = OpentelemetryLiveView.setup()
    _ = OpentelemetryBandit.setup()
    _ = OpentelemetryPhoenix.setup(adapter: :bandit)

    children = [
      Web.Mailer,
      Web.Endpoint,
      Web.Telemetry
    ]

    opts = [strategy: :one_for_one, name: Web.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
