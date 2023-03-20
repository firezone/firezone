defmodule FzHttp.Application do
  use Application

  def start(_type, _args) do
    :telemetry.attach(
      "logger-json-ecto",
      [:fz_http, :repo, :query],
      &LoggerJSON.Ecto.telemetry_logging_handler/4,
      String.to_atom(System.get_env("LOG_LEVEL", "info"))
    )

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
