defmodule FzVpn.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias FzVpn.Interface.WGAdapter

  def start(_type, _args) do
    children = sandbox_children() ++ common_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FzVpn.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp common_children do
    [
      FzVpn.Server,
      FzVpn.StatsPushService
    ]
  end

  defp sandbox_children do
    if WGAdapter.wg_adapter() == WGAdapter.Sandbox do
      [WGAdapter.Sandbox]
    else
      []
    end
  end
end
