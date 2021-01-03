defmodule FgHttp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = case Application.get_env(:fg_http, :minimal) do
      true ->
        [FgHttp.Repo]
      _ ->
        [
          FgHttp.Repo,
          {Phoenix.PubSub, name: :fg_http_pub_sub},
          FgHttpWeb.Endpoint
        ]
    end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FgHttp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    FgHttpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
