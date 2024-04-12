import Config

###############################
##### Domain ##################
###############################

config :domain, Domain.Repo,
  pool_size: 10,
  show_sensitive_data_on_connection_error: false

###############################
##### Web #####################
###############################

config :web, Web.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

###############################
##### API #####################
###############################

config :api, API.Endpoint, server: true

###############################
##### Third-party configs #####
###############################

config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "nonce",
  "fragment",
  "state",
  "token",
  "public_key",
  "private_key",
  "preshared_key"
]

# Do not print debug messages in production and handle all
# other reports by Elixir Logger with JSON back-end so that.
# we can parse them in log analysis tools.
# Notice: SASL reports turned off because of their verbosity.
# Notice: Log level can be overridden on production with LOG_LEVEL environment variable.
config :logger,
  handle_sasl_reports: false,
  handle_otp_reports: true

config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.GoogleCloud, metadata: {:all_except, [:socket, :conn]}}

config :logger, level: :info

config :swoosh, local: false
