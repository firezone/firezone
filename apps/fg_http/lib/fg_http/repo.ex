defmodule FgHttp.Repo do
  use Ecto.Repo,
    otp_app: :fg_http,
    adapter: Ecto.Adapters.Postgres

  alias FgHttp.Devices
  require Logger
  import FgHttpWeb.EventHelpers

  def init(_) do
    # Notify FgVpn.Server the config has been loaded
    send(vpn_pid(), {:set_config, Devices.to_peer_list()})
  end
end
