defmodule FzVpn.Application do
  use Application

  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: __MODULE__.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  defp children do
    Application.fetch_env!(:fz_vpn, :supervised_children)
  end
end
