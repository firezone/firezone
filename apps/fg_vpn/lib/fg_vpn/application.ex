defmodule FgVpn.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    pubkeys = ["hello", "world"]

    children = [
      {FgVpn.Config, pubkeys}
      # Starts a worker by calling: FgVpn.Worker.start_link(arg)
      # {FgVpn.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FgVpn.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
