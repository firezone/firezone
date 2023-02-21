import Config

config :fz_http, FzHttpWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

# This will be overridden on releases

config :fz_http, FzHttp.Repo,
  pool_size: 10,
  show_sensitive_data_on_connection_error: false

config :fz_http,
  http_client: HTTPoison,
  connectivity_checks_url: "https://ping.firez.one/"

###############################
##### FZ VPN configs ##########
###############################

config :fz_wall,
  nft_path: "nft",
  cli: FzWall.CLI.Sandbox

###############################
##### Third-party configs #####
###############################

config :logger, level: :info

config :swoosh, local: false
