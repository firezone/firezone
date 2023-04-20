defmodule Domain.Application do
  use Application

  def start(_type, _args) do
    result =
      Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)

    :ok = after_start()
    result
  end

  # TODO: when app starts for migrations set env to disable connectivity checks and telemetry
  def children do
    [
      # Infrastructure services
      Domain.Repo,
      Domain.Vault,
      {Phoenix.PubSub, name: Domain.PubSub},

      # Application
      {Domain.Notifications, name: Domain.Notifications},
      # Domain.Auth,
      Domain.Relays,
      Domain.Gateways,
      Domain.Clients,

      # Observability
      Domain.ConnectivityChecks,
      Domain.Telemetry
    ]
  end

  if Mix.env() == :prod do
    defp after_start do
      Domain.Config.validate_runtime_config!()
    end
  else
    defp after_start do
      :ok
    end
  end
end
