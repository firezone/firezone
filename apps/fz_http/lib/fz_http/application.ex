defmodule FzHttp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
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
      FzHttp.Server,
      FzHttp.Repo,
      FzHttp.Vault,
      FzHttpWeb.Endpoint,
      {Phoenix.PubSub, name: FzHttp.PubSub},
      FzHttpWeb.Presence,
      FzHttp.ConnectivityCheckService
    ]
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
end
