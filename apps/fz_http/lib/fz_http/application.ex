defmodule FzHttp.Application do
  use Application

  def start(_type, _args) do
    supervision_tree_mode = FzHttp.Config.fetch_env!(:fz_http, :supervision_tree_mode)

    result =
      supervision_tree_mode
      |> children()
      |> Supervisor.start_link(strategy: :one_for_one, name: __MODULE__.Supervisor)

    :ok = after_start()

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    FzHttpWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # TODO: get rid off this
  defp children(:full) do
    [
      # Infrastructure services
      FzHttp.Repo,
      FzHttp.Vault,
      {Phoenix.PubSub, name: FzHttp.PubSub},
      {FzHttp.Notifications, name: FzHttp.Notifications},
      FzHttpWeb.Presence,

      # Application
      # {Postgrex.Notifications, [name: FzHttp.Repo.Notifications] ++ FzHttp.Repo.config()},
      # FzHttp.Repo.Notifier,
      FzHttp.Server,
      FzHttp.VpnSessionScheduler,
      FzHttp.SAML.StartProxy,
      {DynamicSupervisor, name: FzHttp.RefresherSupervisor, strategy: :one_for_one},
      FzHttp.OIDC.RefreshManager,
      FzHttpWeb.Endpoint,

      # Observability
      FzHttp.ConnectivityChecks,
      FzHttp.Telemetry
    ]
  end

  defp children(:test) do
    [
      # Infrastructure services
      FzHttp.Repo,
      FzHttp.Vault,
      {Phoenix.PubSub, name: FzHttp.PubSub},
      {FzHttp.Notifications, name: FzHttp.Notifications},
      FzHttpWeb.Presence,

      # Application
      FzHttp.Server,
      FzHttp.SAML.StartProxy,
      FzHttpWeb.Endpoint,

      # Observability
      FzHttp.ConnectivityChecks,
      FzHttp.Telemetry
    ]
  end

  defp children(:database) do
    [
      FzHttp.Repo,
      FzHttp.Vault
    ]
  end

  if Mix.env() == :prod do
    defp after_start do
      FzHttp.Config.validate_runtime_config!()
    end
  else
    defp after_start do
      :ok
    end
  end
end
