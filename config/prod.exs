import Config

###############################
##### Domain ##################
###############################

config :domain, Domain.Repo,
  pool_size: 10,
  show_sensitive_data_on_connection_error: false

config :domain, Domain.ConnectivityChecks, url: "https://ping.firez.one/"

###############################
##### Web #####################
###############################

config :web, Web.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

###############################
##### Third-party configs #####
###############################

config :logger, level: :info

config :swoosh, local: false
