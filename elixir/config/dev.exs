import Config

# Local vars
web_port = System.get_env("PHOENIX_WEB_PORT", "13443") |> String.to_integer()
api_port = System.get_env("PHOENIX_API_PORT", "13001") |> String.to_integer()

# DATABASE_SSL can be "true", "false", or a JSON object with SSL options
db_ssl =
  case System.get_env("DATABASE_SSL", "false") do
    "true" -> true
    "false" -> false
    json -> json |> JSON.decode!() |> Portal.Config.Dumper.dump_ssl_opts()
  end

db_opts = [
  database: System.get_env("DATABASE_NAME", "firezone_dev"),
  username: System.get_env("DATABASE_USER", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  ssl: db_ssl
]

###############################
##### Portal ##################
###############################

config :portal, Portal.Repo, db_opts

config :portal, Portal.ChangeLogs.ReplicationConnection,
  replication_slot_name: db_opts[:database] <> "_clog_slot",
  publication_name: db_opts[:database] <> "_clog_pub",
  connection_opts: db_opts

config :portal, Portal.Changes.ReplicationConnection,
  replication_slot_name: db_opts[:database] <> "_changes_slot",
  publication_name: db_opts[:database] <> "_changes_pub",
  connection_opts: db_opts

config :portal, outbound_email_adapter_configured?: true

config :portal, run_manual_migrations: true

config :portal, Portal.ComponentVersions,
  firezone_releases_url: "http://localhost:3000/api/releases"

config :portal, Portal.Billing,
  enabled: System.get_env("BILLING_ENABLED", "false") == "true",
  secret_key: System.get_env("STRIPE_SECRET_KEY", "sk_dev_1111"),
  webhook_signing_secret: System.get_env("STRIPE_WEBHOOK_SIGNING_SECRET", "whsec_dev_1111"),
  default_price_id: System.get_env("STRIPE_DEFAULT_PRICE_ID", "price_1OkUIcADeNU9NGxvTNA4PPq6")

# For dev, we want to run things very frequently to aid development and testing.
worker_dev_schedule = System.get_env("WORKER_DEV_SCHEDULE", "* * * * *")

# Oban has its own config validation that prevents overriding config in runtime.exs,
# so we explicitly set the config in dev.exs, test.exs, and runtime.exs (for prod) only.
config :portal, Oban,
  plugins: [
    # Keep the last 7 days of completed, cancelled, and discarded jobs
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},

    # Rescue jobs that have been stuck in executing state due to node crashes,
    # deploys, or other issues. Jobs will be moved back to available state
    # after the timeout.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(1)},

    # Periodic jobs
    {Oban.Plugins.Cron,
     crontab: [
       {worker_dev_schedule, Portal.Entra.Scheduler},
       {worker_dev_schedule, Portal.Google.Scheduler},
       {worker_dev_schedule, Portal.Okta.Scheduler},
       {worker_dev_schedule, Portal.Workers.SyncErrorNotification,
        args: %{provider: "entra", frequency: "daily"}},
       {worker_dev_schedule, Portal.Workers.SyncErrorNotification,
        args: %{provider: "google", frequency: "daily"}},
       {worker_dev_schedule, Portal.Workers.SyncErrorNotification,
        args: %{provider: "entra", frequency: "three_days"}},
       {worker_dev_schedule, Portal.Workers.SyncErrorNotification,
        args: %{provider: "google", frequency: "three_days"}},
       {worker_dev_schedule, Portal.Workers.SyncErrorNotification,
        args: %{provider: "entra", frequency: "weekly"}},
       {worker_dev_schedule, Portal.Workers.SyncErrorNotification,
        args: %{provider: "google", frequency: "weekly"}},
       {worker_dev_schedule, Portal.Workers.DeleteExpiredPolicyAuthorizations},
       {worker_dev_schedule, Portal.Workers.CheckAccountLimits},
       {worker_dev_schedule, Portal.Workers.OutdatedGateways},
       {worker_dev_schedule, Portal.Workers.DeleteExpiredClientTokens},
       {worker_dev_schedule, Portal.Workers.DeleteExpiredAPITokens},
       {worker_dev_schedule, Portal.Workers.DeleteExpiredOneTimePasscodes},
       {worker_dev_schedule, Portal.Workers.DeleteExpiredPortalSessions}
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
  repo: Portal.Repo

config :portal, Portal.Okta.AuthProvider,
  redirect_uri: "https://localhost:#{web_port}/auth/oidc/callback"

###############################
##### PortalWeb Endpoint ######
###############################

config :portal, dev_routes: true

config :portal, PortalWeb.Endpoint,
  url: [scheme: "https", host: "localhost", port: web_port],
  https: [
    port: web_port,
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
    esbuild: {Esbuild, :install_and_run, [:portal, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:portal, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"config/.*(exs)$",
      ~r"lib/portal/.*(ex|eex|heex)$",
      ~r"lib/portal_web/.*(ex|eex|heex)$",
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$"
    ]
  ],
  reloadable_apps: [:portal],
  server: true

config :portal,
  api_external_url: "http://localhost:#{api_port}"

config :phoenix_live_reload, :dirs, [File.cwd!()]

config :portal, PortalWeb.Plugs.SecureHeaders,
  csp_policy: [
    "default-src 'self' 'nonce-${nonce}' https://firezone.statuspage.io",
    "img-src 'self' data: https://www.gravatar.com https://www.firezone.dev https://firezone.statuspage.io",
    "style-src 'self' 'unsafe-inline'",
    "script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com/"
  ]

# Note: on Linux you may need to add `--add-host=host.docker.internal:host-gateway`
# to the `docker run` command. Works on Docker v20.10 and above.
config :portal, api_url_override: "ws://host.docker.internal:#{api_port}/"

###############################
##### PortalAPI Endpoint ######
###############################

config :portal, PortalAPI.Endpoint,
  http: [port: api_port],
  debug_errors: true,
  code_reloader: true,
  check_origin: ["//10.0.2.2", "//127.0.0.1", "//localhost"],
  watchers: [],
  server: true

###############################
##### Third-party configs #####
###############################

config :geolix,
  # Download from maxmind.com (requires free account)
  databases: [
    %{
      id: :city,
      adapter: Geolix.Adapter.MMDB2,
      source: Path.expand("../priv/geoip/GeoLite2-City.mmdb", __DIR__)
    }
  ]

# Include only message and custom metadata in development logs
# This filters out Phoenix's automatic metadata like pid, request_id, etc.
config :logger, :default_formatter,
  format: {PortalWeb.LogFormatter, :format},
  metadata: :all

# Disable caching for OpenAPI spec to ensure it is refreshed
config :open_api_spex, :cache_adapter, OpenApiSpex.Plug.NoneCache

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :portal, Portal.Mailer, adapter: Swoosh.Adapters.Local

config :sentry,
  environment_name: :dev
