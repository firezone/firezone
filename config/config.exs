# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
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

# Configures the endpoint
config :fg_http, FgHttpWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  render_errors: [view: FgHttpWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: FgHttp.PubSub

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
