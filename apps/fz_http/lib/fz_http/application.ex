defmodule FzHttp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias FzHttp.Telemetry

  def start(_type, _args) do
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    Telemetry.fz_http_started()
    opts = [strategy: :one_for_one, name: FzHttp.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    FzHttpWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp children, do: children(Application.fetch_env!(:fz_http, :supervision_tree_mode))

  defp children(:full) do
    [
      {Cachex, name: :conf},
      {Cachex, name: :revoked_api_tokens},
      FzHttp.Server,
      FzHttp.Repo,
      {Postgrex.Notifications, [name: FzHttp.Repo.Notifications] ++ FzHttp.Repo.config()},
      FzHttp.Repo.Notifier,
      FzHttp.Vault,
      FzHttp.Configurations.Cache,
      FzHttpWeb.Endpoint,
      {Phoenix.PubSub, name: FzHttp.PubSub},
      {FzHttp.Notifications, name: FzHttp.Notifications},
      FzHttpWeb.Presence,
      FzHttp.ConnectivityCheckService,
      FzHttp.TelemetryPingService,
      FzHttp.VpnSessionScheduler,
      FzHttp.OIDC.StartProxy,
      {DynamicSupervisor, name: FzHttp.RefresherSupervisor, strategy: :one_for_one},
      FzHttp.OIDC.RefreshManager,
      FzHttp.SAML.StartProxy
    ]
  end

  defp children(:test) do
    [
      {Cachex, name: :conf},
      FzHttp.Server,
      FzHttp.Repo,
      FzHttp.Vault,
      FzHttp.Configurations.Cache,
      FzHttpWeb.Endpoint,
      {FzHttp.OIDC.StartProxy, :test},
      {Phoenix.PubSub, name: FzHttp.PubSub},
      {FzHttp.Notifications, name: FzHttp.Notifications},
      FzHttpWeb.Presence,
      FzHttp.SAML.StartProxy
    ]
  end
end
