import Config

alias FzCommon.ConfigHelpers

# Configure your database
if url = System.get_env("DATABASE_URL") do
  config :fz_http, FzHttp.Repo,
    url: url,
    show_sensitive_data_on_connection_error: true,
    pool_size: 10
else
  config :fz_http, FzHttp.Repo,
    username: "postgres",
    password: "postgres",
    database: "firezone_dev",
    ssl: false,
    ssl_opts: [],
    parameters: [],
    hostname: "localhost",
    show_sensitive_data_on_connection_error: true,
    pool_size: 10
end

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we use it
# with webpack to recompile .js and .css sources.
config :fz_http, FzHttpWeb.Endpoint,
  http: [port: 4000],
  debug_errors: true,
  code_reloader: true,
  url: [host: "localhost", scheme: "http"],
  check_origin: ["//127.0.0.1", "//localhost"],
  watchers: [
    node: [
      "node_modules/webpack/bin/webpack.js",
      "--mode",
      "development",
      "--watch",
      "--watch-options-stdin",
      cd: Path.expand("../apps/fz_http/assets", __DIR__)
    ]
  ]

config :fz_vpn,
  wg_path: "wg",
  cli: FzVpn.CLI.Sandbox

get_egress_interface = fn ->
  egress_interface_cmd = "route | grep '^default' | grep -o '[^ ]*$'"
  System.cmd("/bin/sh", ["-c", egress_interface_cmd]) |> elem(0) |> String.trim()
end

egress_interface = System.get_env("EGRESS_INTERFACE") || get_egress_interface.()

config :fz_wall,
  nft_path: "nft",
  egress_interface: egress_interface,
  cli: FzWall.CLI.Sandbox

# Auth
local_auth_enabled = (System.get_env("LOCAL_AUTH_ENABLED") && true) || false
okta_auth_enabled = (System.get_env("OKTA_AUTH_ENABLED") && true) || false
google_auth_enabled = (System.get_env("GOOGLE_AUTH_ENABLED") && true) || false

# Configure strategies
identity_strategy =
  {:identity, {Ueberauth.Strategy.Identity, [callback_methods: ["POST"], uid_field: :email]}}

okta_strategy = {:okta, {Ueberauth.Strategy.Okta, []}}
google_strategy = {:google, {Ueberauth.Strategy.Google, []}}

providers =
  [
    {local_auth_enabled, identity_strategy},
    {google_auth_enabled, google_strategy},
    {okta_auth_enabled, okta_strategy}
  ]
  |> Enum.filter(fn {key, _val} -> key end)
  |> Enum.map(fn {_key, val} -> val end)

config :ueberauth, Ueberauth, providers: providers

if okta_auth_enabled do
  config :ueberauth, Ueberauth.Strategy.Okta.OAuth,
    client_id: System.get_env("OKTA_CLIENT_ID"),
    client_secret: System.get_env("OKTA_CLIENT_SECRET"),
    site: System.get_env("OKTA_SITE")
end

if google_auth_enabled do
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: System.get_env("GOOGLE_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
    redirect_uri: System.get_env("GOOGLE_REDIRECT_URI")
end

# ## SSL Support
#
# In order to use HTTPS in development, a self-signed
# certificate can be generated by running the following
# Mix task:
#
#     mix phx.gen.cert
#
# Note that this task requires Erlang/OTP 20 or later.
# Run `mix help phx.gen.cert` for more information.
#
# The `http:` config above can be replaced with:
#
#     https: [
#       port: 4001,
#       cipher_suite: :strong,
#       keyfile: "priv/cert/selfsigned_key.pem",
#       certfile: "priv/cert/selfsigned.pem"
#     ],
#
# If desired, both `http:` and `https:` keys can be
# configured to run both http and https servers on
# different ports.

# Watch static and templates for browser reloading.
config :fz_http, FzHttpWeb.Endpoint,
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  live_view: [
    signing_salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDejX"
  ],
  live_reload: [
    patterns: [
      ~r"apps/fz_http/priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/fz_http/priv/gettext/.*(po)$",
      ~r"apps/fz_http/lib/fz_http_web/(live|views)/.*(ex)$",
      ~r"apps/fz_http/lib/fz_http_web/templates/.*(eex)$"
    ]
  ]

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :fz_http,
  telemetry_module: FzCommon.MockTelemetry,
  local_auth_enabled: local_auth_enabled,
  okta_auth_enabled: google_auth_enabled,
  google_auth_enabled: okta_auth_enabled
