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

config :cf_http,
  ecto_repos: [CfHttp.Repo],
  vpn_endpoint: "127.0.0.1:51820",
  admin_user_email: "cloudfire@localhost",
  events_module: CfHttpWeb.Events,
  disable_signup: true

config :cf_wall,
  cli: CfWall.CLI.Sandbox,
  server_process_opts: []

# This will be changed per-env
config :cf_vpn,
  private_key: "UAeZoaY95pKZE1Glq28sI2GJDfGGRFtlb4KC6rjY2Gs=",
  cli: CfVpn.CLI.Sandbox,
  server_process_opts: []

# Configures the endpoint
# These will be overridden at runtime in production by config/releases.exs
config :cf_http, CfHttpWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: CfHttpWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: CfHttp.PubSub

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Configures the vault
config :cf_http, CfHttp.Vault,
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

config :cf_common, :config_file_module, File

config :cf_vpn, CfVpn, crate: :cf_vpn, mode: :debug

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
