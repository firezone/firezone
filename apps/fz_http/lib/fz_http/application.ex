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
    # Pull in OpenIDConnect config if available
    openid_connect_providers = Application.get_env(:fz_http, :openid_connect_providers)

    [
      FzHttp.Server,
      FzHttp.Repo,
      FzHttp.Vault,
      FzHttpWeb.Endpoint,
      {Phoenix.PubSub, name: FzHttp.PubSub},
      FzHttpWeb.Presence,
      FzHttp.ConnectivityCheckService,
      FzHttp.VpnSessionScheduler
    ]
    |> append_if(openid_connect_providers, {OpenIDConnect.Worker, openid_connect_providers})
  end

  defp children(:test) do
    [
      FzHttp.Server,
      FzHttp.Repo,
      FzHttp.Vault,
      FzHttpWeb.Endpoint,
      {Phoenix.PubSub, name: FzHttp.PubSub},
      FzHttpWeb.Presence
    ]
  end

  defp append_if(list, condition, item) do
    if condition, do: list ++ [item], else: list
  end
end
