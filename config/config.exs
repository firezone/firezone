# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# *Note*:
# This configuration is generated on compile time. To configure the application during runtime,
# use releases.exs. These configuration options are overridden by environment-specific
# configuration files.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :fz_http,
  ecto_repos: [FzHttp.Repo],
  admin_email: "firezone@localhost",
  default_admin_password: "firezone",
  events_module: FzHttpWeb.Events,
  disable_signup: true,
  server_process_opts: [name: {:global, :fz_http_server}]

config :fz_wall,
  cli: FzWall.CLI.Sandbox,
  server_process_opts: [name: {:global, :fz_wall_server}]

# This will be changed per-env
config :fz_vpn,
  wireguard_public_key: "cB2yQeCxHO/qCH8APoM2D2Anf4Yd7sRLyfS7su71K3M=",
  wireguard_interface_name: "wg-firezone",
  wireguard_port: "51820",
  wireguard_endpoint_ip: "127.0.0.1",
  cli: FzVpn.CLI.Sandbox,
  server_process_opts: [name: {:global, :fz_vpn_server}]

# Configures the endpoint
# These will be overridden at runtime in production by config/releases.exs
config :fz_http, FzHttpWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: FzHttpWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: FzHttp.PubSub

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Configures the vault
config :fz_http, FzHttp.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      # In AES.GCM, it is important to specify 12-byte IV length for
      # interoperability with other encryption software. See this GitHub
      # issue for more details:
      # https://github.com/danielberkompas/cloak/issues/93
      #
      # In Cloak 2.0, this will be the default iv length for AES.GCM.
      tag: "AES.GCM.V1",
      key: Base.decode64!("XXJ/NGevpvkG9219RYsz21zZWR7CZ//CqA0ARPIBqys="),
      iv_length: 12
    }
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
