import Config

logger_secret_keys = [
  "password",
  "secret",
  "nonce",
  "fragment",
  "state",
  "token",
  "public_key",
  "private_key",
  "preshared_key",
  "session",
  "sessions"
]

###############################
##### Domain ##################
###############################

config :domain, Domain.Repo,
  pool_size: 10,
  show_sensitive_data_on_connection_error: false

config :domain, :logger_json,
  metadata: {:all_except, [:socket, :conn]},
  redactors: [
    {LoggerJSON.Redactors.RedactKeys, logger_secret_keys}
  ]

###############################
##### Web #####################
###############################

config :web, Web.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :web, :logger_json,
  metadata: {:all_except, [:socket, :conn]},
  redactors: [
    {LoggerJSON.Redactors.RedactKeys, logger_secret_keys}
  ]

###############################
##### API #####################
###############################

config :api, API.Endpoint, server: true

config :api, :logger_json,
  metadata: {:all_except, [:socket, :conn]},
  redactors: [
    {LoggerJSON.Redactors.RedactKeys, logger_secret_keys}
  ]

###############################
##### Third-party configs #####
###############################

config :phoenix, :filter_parameters, logger_secret_keys

# Do not print debug messages in production and handle all
# other reports by Elixir Logger with JSON back-end so that.
# we can parse them in log analysis tools.
# Notice: SASL reports turned off because of their verbosity.
# Notice: Log level can be overridden on production with LOG_LEVEL environment variable.
config :logger,
  handle_sasl_reports: false,
  handle_otp_reports: true

config :logger, level: :info

config :swoosh, local: false
