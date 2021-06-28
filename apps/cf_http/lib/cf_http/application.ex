defmodule CfHttp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children =
      case Application.get_env(:cf_http, :minimal) do
        true ->
          [
            CfHttp.Repo,
            CfHttp.Vault
          ]

        _ ->
          [
            CfHttp.Repo,
            CfHttp.Vault,
            {Phoenix.PubSub, name: CfHttp.PubSub},
            CfHttpWeb.Endpoint
          ]
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CfHttp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    CfHttpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
