defmodule FgHttp.Repo do
  use Ecto.Repo,
    otp_app: :fg_http,
    adapter: Ecto.Adapters.Postgres

  alias FgHttp.Devices
  require Logger
  import FgHttpWeb.Events

  def init(_) do
    # Set firewall rules
    set_rules()

    # Set WireGuard peer config
    set_config()
  end
end
