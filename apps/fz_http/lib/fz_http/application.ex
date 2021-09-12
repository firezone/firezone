defmodule FzHttp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children =
      case Application.get_env(:fz_http, :minimal) do
        true ->
          [
            FzHttp.Repo,
            FzHttp.Vault
          ]

        _ ->
          [
            FzHttp.Server,
            FzHttp.Repo,
            FzHttp.Vault,
            {Phoenix.PubSub, name: FzHttp.PubSub},
            FzHttpWeb.Endpoint
          ]
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FzHttp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    FzHttpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
