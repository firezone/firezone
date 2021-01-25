defmodule FgHttp.Repo do
  use Ecto.Repo,
    otp_app: :fg_http,
    adapter: Ecto.Adapters.Postgres

  alias FgHttp.Devices
  alias Phoenix.PubSub

  def init(_) do
    # Notify FgVpn.Server the config has been loaded
    PubSub.broadcast(:fg_http_pub_sub, "server", {:set_config, Devices.to_peer_list()})
  end
end
