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

###############################
##### Web #####################
###############################

config :web, dev_routes: true

config :web, Web.Endpoint,
  http: [port: 13000],
  code_reloader: true,
  debug_errors: true,
  check_origin: ["//127.0.0.1", "//localhost"],
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:web, ~w(--watch)]}
  ],
  live_reload: [
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
    "default-src 'self' 'nonce-${nonce}'",
    "img-src 'self' data: https://www.gravatar.com",
    "style-src 'self' 'unsafe-inline'",
    "script-src 'self' 'unsafe-inline'",
    "connect-src 'self' data: https://firezone.statuspage.io"
  ]

###############################
##### API #####################
###############################

config :api, dev_routes: true

config :api, API.Endpoint,
  http: [port: 13001],
  debug_errors: true,
  code_reloader: true,
  check_origin: ["//127.0.0.1", "//localhost"],
  watchers: [],
  server: true

###############################
##### Third-party configs #####
###############################

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :web, Web.Mailer, adapter: Swoosh.Adapters.Local
