defmodule CfHttp.Repo do
  use Ecto.Repo,
    otp_app: :cf_http,
    adapter: Ecto.Adapters.Postgres

  require Logger
  import CfHttpWeb.Events

  def init(_) do
    # Set firewall rules
    set_rules()

    # Set WireGuard peer config
    set_config()
  end
end
