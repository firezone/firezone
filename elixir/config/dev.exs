import Config

###############################
##### Domain ##################
###############################

db_opts = [
  database: System.get_env("DATABASE_NAME", "firezone_dev"),
  username: System.get_env("DATABASE_USER", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  password: System.get_env("DATABASE_PASSWORD", "postgres")
]

config :domain, Domain.Repo, db_opts

config :domain, Domain.ChangeLogs.ReplicationConnection,
  replication_slot_name: db_opts[:database] <> "_clog_slot",
  publication_name: db_opts[:database] <> "_clog_pub",
  connection_opts: db_opts

config :domain, Domain.Changes.ReplicationConnection,
  replication_slot_name: db_opts[:database] <> "_changes_slot",
  publication_name: db_opts[:database] <> "_changes_pub",
  connection_opts: db_opts

config :domain, outbound_email_adapter_configured?: true

config :domain, run_manual_migrations: true

config :domain, Domain.ComponentVersions,
  firezone_releases_url: "http://localhost:3000/api/releases"

config :domain, Domain.Billing,
  enabled: System.get_env("BILLING_ENABLED", "false") == "true",
  secret_key: System.get_env("STRIPE_SECRET_KEY", "sk_dev_1111"),
  webhook_signing_secret: System.get_env("STRIPE_WEBHOOK_SIGNING_SECRET", "whsec_dev_1111"),
  default_price_id: System.get_env("STRIPE_DEFAULT_PRICE_ID", "price_1OkUIcADeNU9NGxvTNA4PPq6")

# For dev, we want to run things very frequently to aid development and testing.
worker_dev_schedule = System.get_env("WORKER_DEV_SCHEDULE", "* * * * *")

# Oban has its own config validation that prevents overriding config in runtime.exs,
# so we explicitly set the config in dev.exs, test.exs, and runtime.exs (for prod) only.
config :domain, Oban,
  plugins: [
    # Keep the last 90 days of completed, cancelled, and discarded jobs
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 90},

    # Rescue jobs that have been stuck in executing state due to node crashes,
    # deploys, or other issues. Jobs will be moved back to available state
    # after the timeout.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(1)},

    # Periodic jobs
    {Oban.Plugins.Cron,
     crontab: [
       {worker_dev_schedule, Domain.Entra.Scheduler},
       {worker_dev_schedule, Domain.Google.Scheduler},
       {worker_dev_schedule, Domain.Okta.Scheduler},
       {worker_dev_schedule, Domain.Workers.SyncErrorNotification,
        args: %{provider: "entra", frequency: "daily"}},
       {worker_dev_schedule, Domain.Workers.SyncErrorNotification,
        args: %{provider: "google", frequency: "daily"}},
       {worker_dev_schedule, Domain.Workers.SyncErrorNotification,
        args: %{provider: "entra", frequency: "three_days"}},
       {worker_dev_schedule, Domain.Workers.SyncErrorNotification,
        args: %{provider: "google", frequency: "three_days"}},
       {worker_dev_schedule, Domain.Workers.SyncErrorNotification,
        args: %{provider: "entra", frequency: "weekly"}},
       {worker_dev_schedule, Domain.Workers.SyncErrorNotification,
        args: %{provider: "google", frequency: "weekly"}},
       {worker_dev_schedule, Domain.Workers.DeleteExpiredPolicyAuthorizations},
       {worker_dev_schedule, Domain.Workers.CheckAccountLimits},
       {worker_dev_schedule, Domain.Workers.OutdatedGateways},
       {worker_dev_schedule, Domain.Workers.DeleteExpiredClientTokens},
       {worker_dev_schedule, Domain.Workers.DeleteExpiredAPITokens},
       {worker_dev_schedule, Domain.Workers.DeleteExpiredOneTimePasscodes},
       {worker_dev_schedule, Domain.Workers.DeleteExpiredPortalSessions}
     ]}
  ],
  queues: [
    default: 10,
    entra_scheduler: 1,
    entra_sync: 5,
    google_scheduler: 1,
    google_sync: 5,
    okta_scheduler: 1,
    okta_sync: 5,
    sync_error_notifications: 1
  ],
  engine: Oban.Engines.Basic,
  repo: Domain.Repo

config :domain, Domain.Okta.AuthProvider,
  redirect_uri: "https://localhost:13443/auth/oidc/callback"

###############################
##### Web #####################
###############################

config :web, dev_routes: true

config :web, Web.Endpoint,
  url: [scheme: "https", host: "localhost", port: 13443],
  https: [
    port: 13_443,
    cipher_suite: :strong,
    certfile: "priv/cert/selfsigned.pem",
    keyfile: "priv/cert/selfsigned_key.pem"
  ],
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
    "default-src 'self' 'nonce-${nonce}' https://api-js.mixpanel.com https://firezone.statuspage.io",
    "img-src 'self' data: https://www.gravatar.com https://track.hubspot.com https://www.firezone.dev https://firezone.statuspage.io",
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

# Include only message and custom metadata in development logs
# This filters out Phoenix's automatic metadata like pid, request_id, etc.
config :logger, :default_formatter,
  format: {Web.LogFormatter, :format},
  metadata: :all

# Disable caching for OpenAPI spec to ensure it is refreshed
config :open_api_spex, :cache_adapter, OpenApiSpex.Plug.NoneCache

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :domain, Domain.Mailer, adapter: Swoosh.Adapters.Local

config :workos, WorkOS.Client,
  api_key: System.get_env("WORKOS_API_KEY"),
  client_id: System.get_env("WORKOS_CLIENT_ID"),
  baseurl: System.get_env("WORKOS_BASE_URL", "https://api.workos.com")

config :sentry,
  environment_name: :dev
