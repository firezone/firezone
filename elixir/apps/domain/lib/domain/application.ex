defmodule Domain.Application do
  use Application

  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  def children do
    [
      # Infrastructure services
      Domain.Repo,
      {Phoenix.PubSub, name: Domain.PubSub},

      # Application
      Domain.Auth,
      Domain.Relays,
      Domain.Gateways,
      Domain.Devices

      # Observability
      # Domain.Telemetry
    ]
  end
end
