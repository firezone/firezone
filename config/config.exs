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

config :fg_http,
  ecto_repos: [FgHttp.Repo]

config :fg_vpn,
  wireguard_conf_path:
    config(:fg_http,
      vpn_endpoint: "localhost:51820"
    )

# Configures the endpoint
# These will be overridden at runtime in production by config/releases.exs
config :fg_http, FgHttpWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: FgHttpWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: :fg_http_pub_sub

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
