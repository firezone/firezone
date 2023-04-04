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

config :web, Web.Endpoint,
  http: [port: 13000],
  debug_errors: true,
  code_reloader: true,
  check_origin: ["//127.0.0.1", "//localhost"],
  watchers: [
    node: ["esbuild.js", "dev", cd: Path.expand("../apps/web/assets", __DIR__)]
  ],
  live_reload: [
    patterns: [
      ~r"apps/web/priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/web/priv/gettext/.*(po)$",
      ~r"apps/web/lib/web_web/(live|views)/.*(ex)$",
      ~r"apps/web/lib/web_web/templates/.*(eex)$"
    ]
  ]

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
