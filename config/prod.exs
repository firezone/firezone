import Config

# For production, don't forget to configure the url host
# to something meaningful, Phoenix uses this information
# when generating URLs.
#
# Note we also include the path to a cache manifest
# containing the digested version of static files. This
# manifest is generated by the `mix phx.digest` task,
# which you should run after static files are built and
# before starting your production server.
config :fz_vpn,
  wg_path: "wg",
  cli: FzVpn.CLI.Sandbox

config :fz_wall,
  nft_path: "nft",
  cli: FzWall.CLI.Sandbox

config :fz_http, FzHttpWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  # changed by release config
  secret_key_base: "dummy",
  # changed by release config
  live_view: [signing_salt: "dummy"],
  server: true

# This will be overridden on releases
if url = System.get_env("DATABASE_URL") do
  config :fz_http, FzHttp.Repo,
    url: url,
    pool_size: 10
else
  config :fz_http, FzHttp.Repo,
    username: "postgres",
    password: "postgres",
    database: "firezone",
    hostname: "localhost",
    pool_size: 10
end

# Do not print debug messages in production
config :logger, level: :info

config :fz_http,
  local_auth_enabled: true,
  google_auth_enabled: true,
  okta_auth_enabled: true,
  connectivity_checks_url: "https://ping.firez.one/"

config :ueberauth, Ueberauth,
  providers: [
    {:identity, {Ueberauth.Strategy.Identity, [callback_methods: ["POST"], uid_field: :email]}},
    {:okta, {Ueberauth.Strategy.Okta, []}},
    {:google, {Ueberauth.Strategy.Google, []}}
  ]
