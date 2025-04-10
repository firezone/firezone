import Config

###############################
##### Domain ##################
###############################

config :domain, Domain.Repo,
  database: System.get_env("DATABASE_NAME", "firezone_dev"),
  username: System.get_env("DATABASE_USER", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  password: System.get_env("DATABASE_PASSWORD", "postgres")

config :domain, outbound_email_adapter_configured?: true

config :domain, Domain.Billing,
  secret_key: System.get_env("STRIPE_SECRET_KEY", "sk_dev_1111"),
  webhook_signing_secret: System.get_env("STRIPE_WEBHOOK_SIGNING_SECRET", "whsec_dev_1111")

###############################
##### Web #####################
###############################

config :web, dev_routes: true

config :web, Web.Endpoint,
  http: [port: 13_000],
  code_reloader: true,
  debug_errors: true,
  check_origin: [
    # Android emulator
    "//10.0.2.2",
    "//127.0.0.1",
    "//localhost"
  ],
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:web, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"apps/config/.*(exs)$",
      ~r"apps/domain/lib/domain/.*(ex|eex|heex)$",
      ~r"apps/web/priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/web/priv/gettext/.*(po)$",
      ~r"apps/web/lib/web/.*(ex|eex|heex)$"
    ]
  ],
  reloadable_apps: [:domain, :web],
  server: true

config :web,
  api_external_url: "http://localhost:13001"

root_path =
  __ENV__.file
  |> Path.dirname()
  |> Path.join("..")
  |> Path.expand()

config :phoenix_live_reload, :dirs, [
  Path.join([root_path, "apps", "domain"]),
  Path.join([root_path, "apps", "web"]),
  Path.join([root_path, "apps", "api"])
]

config :web, Web.Plugs.SecureHeaders,
  csp_policy: [
    "default-src 'self' 'nonce-${nonce}' https://api-js.mixpanel.com",
    "img-src 'self' data: https://www.gravatar.com https://track.hubspot.com https://www.firezone.dev",
    "style-src 'self' 'unsafe-inline'",
    "script-src 'self' 'unsafe-inline' http://cdn.mxpnl.com http://*.hs-analytics.net https://cdn.tailwindcss.com/"
  ]

# Note: on Linux you may need to add `--add-host=host.docker.internal:host-gateway`
# to the `docker run` command. Works on Docker v20.10 and above.
config :web, api_url_override: "ws://host.docker.internal:13001/"

###############################
##### API #####################
###############################

config :api, dev_routes: true

config :api, API.Endpoint,
  http: [port: 13_001],
  debug_errors: true,
  code_reloader: true,
  check_origin: ["//10.0.2.2", "//127.0.0.1", "//localhost"],
  watchers: [],
  server: true

###############################
##### Third-party configs #####
###############################

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Disable caching for OpenAPI spec to ensure it is refreshed
config :open_api_spex, :cache_adapter, OpenApiSpex.Plug.NoneCache

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :domain, Domain.Mailer, adapter: Swoosh.Adapters.Local

# Enable the mock adapter for development
config :domain, Domain.Auth.Adapters.Mock.Jobs.SyncDirectory, enabled: true

config :workos, WorkOS.Client,
  api_key: System.get_env("WORKOS_API_KEY"),
  client_id: System.get_env("WORKOS_CLIENT_ID"),
  baseurl: System.get_env("WORKOS_BASE_URL", "https://api.workos.com")

config :sentry,
  environment_name: :dev
