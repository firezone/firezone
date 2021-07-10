defmodule FzHttp.Repo do
  use Ecto.Repo,
    otp_app: :fz_http,
    adapter: Ecto.Adapters.Postgres

  require Logger
  import FzHttpWeb.Events

  def init(_) do
    # Set firewall rules
    set_rules()

    # Set WireGuard peer config
    set_config()
  end
end
