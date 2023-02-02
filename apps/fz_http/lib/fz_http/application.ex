defmodule FzHttp.Application do
  use Application

  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: __MODULE__.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    FzHttpWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp children, do: children(FzHttp.Config.fetch_env!(:fz_http, :supervision_tree_mode))

  defp children(:full) do
    [
      FzHttp.Server,
      FzHttp.Repo,
      {Postgrex.Notifications, [name: FzHttp.Repo.Notifications] ++ FzHttp.Repo.config()},
      FzHttp.Repo.Notifier,
      FzHttp.Vault,
      {Phoenix.PubSub, name: FzHttp.PubSub},
      {FzHttp.Notifications, name: FzHttp.Notifications},
      FzHttpWeb.Presence,
      FzHttp.ConnectivityCheckService,
      FzHttp.TelemetryPingService,
      FzHttp.VpnSessionScheduler,
      FzHttp.SAML.StartProxy,
      {DynamicSupervisor, name: FzHttp.RefresherSupervisor, strategy: :one_for_one},
      FzHttp.OIDC.RefreshManager,
      FzHttpWeb.Endpoint
    ]
  end

  defp children(:test) do
    [
      FzHttp.Server,
      FzHttp.Repo,
      FzHttp.Vault,
      {FzHttp.SAML.StartProxy, :test},
      {Phoenix.PubSub, name: FzHttp.PubSub},
      {FzHttp.Notifications, name: FzHttp.Notifications},
      FzHttpWeb.Presence,
      FzHttpWeb.Endpoint
    ]
  end

  defp children(:database) do
    [
      FzHttp.Repo,
      FzHttp.Vault
    ]
  end
end
