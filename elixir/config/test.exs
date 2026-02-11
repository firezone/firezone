import Config

###############################
##### Portal ##################
###############################

partition_suffix =
  if partition = System.get_env("MIX_TEST_PARTITION") do
    "_p#{partition}"
  else
    ""
  end

config :portal, sql_sandbox: true
# Replica is not used in tests; use the primary DB instead
config :portal, replica_repo: Portal.Repo

# Use ephemeral port for health server to avoid conflicts between test runs
config :portal, Portal.Health, health_port: 0

config :portal, run_manual_migrations: true

config :portal, Portal.Repo,
  database: "firezone_test#{partition_suffix}",
  pool: Ecto.Adapters.SQL.Sandbox,
  queue_target: 1000

config :portal, Portal.Repo.Replica,
  database: "firezone_test#{partition_suffix}",
  pool: Ecto.Adapters.SQL.Sandbox,
  queue_target: 1000

# Oban has its own config validation that prevents overriding config in runtime.exs,
# so we explicitly set the config in dev.exs, test.exs, and runtime.exs (for prod) only.
config :portal, Oban,
  # Periodic jobs don't make sense in tests
  plugins: [
    # Keep the last 90 days of completed, cancelled, and discarded jobs
    # {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 90},

    # Rescue jobs that may have failed due to transient errors like deploys
    # or network issues. It's not guaranteed that the job won't be executed
    # twice, so for now we disable it since all of our Oban jobs can be retried
    # without loss.
    # {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}

    # Periodic jobs
    # {Oban.Plugins.Cron,
    #  crontab: [
    #    # Delete expired policy_authorizations every minute
    #    {"* * * * *", Portal.Workers.DeleteExpiredPolicyAuthorizations}
    #  ]}
  ],
  queues: [default: 10],
  engine: Oban.Engines.Basic,
  repo: Portal.Repo

config :portal, Portal.ChangeLogs.ReplicationConnection,
  replication_slot_name: "test_change_logs_slot",
  publication_name: "test_change_logs_publication",
  enabled: false,
  connection_opts: [
    database: "firezone_test#{partition_suffix}"
  ]

config :portal, Portal.Changes.ReplicationConnection,
  replication_slot_name: "test_changes_slot",
  publication_name: "test_changes_publication",
  enabled: false,
  connection_opts: [
    database: "firezone_test#{partition_suffix}"
  ]

config :portal, Portal.Billing,
  enabled: true,
  secret_key: "sk_test_123",
  webhook_signing_secret: "whsec_test_123",
  default_price_id: "price_test_123",
  plan_product_ids: [
    # Starter
    "prod_test_starter",
    # Team
    "prod_test_team",
    # Enterprise
    "prod_test_enterprise"
  ],
  # Adhoc Device
  adhoc_device_product_id: "prod_test_adhoc_device"

config :portal, Portal.Billing.Stripe.APIClient,
  endpoint: "https://api.stripe.com",
  req_opts: [
    plug: {Req.Test, Portal.Billing.Stripe.APIClient},
    retry: false
  ]

config :portal, Portal.Okta.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.Okta.APIClient},
    retry: false
  ]

config :portal, Portal.Entra.APIClient,
  client_id: "test_client_id",
  client_secret: "test_client_secret",
  endpoint: "https://graph.microsoft.com",
  token_base_url: "https://login.microsoftonline.com",
  req_opts: [
    plug: {Req.Test, Portal.Entra.APIClient},
    retry: false
  ]

config :portal, Portal.Telemetry, enabled: false

config :portal, Portal.ConnectivityChecks, enabled: false

config :portal, Portal.ComponentVersions,
  fetch_from_url: false,
  versions: [
    apple: "1.0.0",
    android: "1.0.0",
    gateway: "1.0.0",
    gui: "1.0.0",
    headless: "1.0.0"
  ]

config :portal, Portal.Google.APIClient,
  endpoint: "https://admin.googleapis.com",
  token_endpoint: "https://oauth2.googleapis.com/token",
  req_opts: [
    retry: false,
    plug: {Req.Test, Portal.Google.APIClient}
  ]

# Auth provider configs with Req.Test for OIDC mocking
config :portal, Portal.Google.AuthProvider,
  req_opts: [
    retry: false,
    plug: {Req.Test, PortalWeb.OIDC}
  ]

config :portal, Portal.Okta.AuthProvider,
  req_opts: [
    retry: false,
    plug: {Req.Test, PortalWeb.OIDC}
  ]

config :portal, Portal.Entra.AuthProvider,
  client_id: "test_auth_provider_client_id",
  req_opts: [
    retry: false,
    plug: {Req.Test, PortalWeb.OIDC}
  ]

config :portal, Portal.OIDC.AuthProvider,
  req_opts: [
    retry: false,
    plug: {Req.Test, PortalWeb.OIDC}
  ]

config :portal, web_external_url: "http://localhost:13100"

# Prevent Oban from running jobs and plugins in tests
config :portal, Oban, testing: :manual

###############################
##### PortalWeb Endpoint ######
###############################

# Use ephemeral port for HTTP server to avoid conflicts between test runs
# Keep url port for URL generation in tests
config :portal, PortalWeb.Endpoint,
  http: [port: 0],
  url: [port: 13_100],
  server: true

config :portal, PortalWeb.Plugs.PutCSPHeader,
  csp_policy: [
    "default-src 'self' 'nonce-${nonce}' https://firezone.statuspage.io",
    "img-src 'self' data: https://www.gravatar.com https://firezone.statuspage.io",
    "style-src 'self' 'unsafe-inline'",
    "script-src 'self' 'unsafe-inline'"
  ]

config :portal, :constant_execution_time, 1
config :portal, replica_repo: Portal.Repo

###############################
##### PortalAPI Endpoint ######
###############################

# Use ephemeral port for HTTP server to avoid conflicts between test runs
config :portal, PortalAPI.Endpoint,
  http: [port: 0],
  url: [port: 13_101],
  server: true

# shorten debounce timeout for tests
config :portal, relays_presence_debounce_timeout_ms: 100

###############################
##### Third-party configs #####
###############################
config :portal, Portal.Mailer, adapter: Portal.Mailer.TestAdapter

# Allow asserting on info logs and higher
config :logger, level: :info

config :argon2_elixir, t_cost: 1, m_cost: 8

config :geolix,
  databases: [
    %{id: :city, adapter: Geolix.Adapter.Fake, data: %{}}
  ]

config :wallaby,
  driver: Wallaby.Chrome,
  screenshot_on_failure: true,
  # TODO: Contribute to Wallaby to make this configurable on the per-process level,
  # along with buffer to write logs only on process failure
  js_logger: false,
  hackney_options: [timeout: 10_000, recv_timeout: 10_000]

ex_unit_config =
  [
    formatters: [JUnitFormatter, ExUnit.CLIFormatter],
    capture_log: true,
    exclude: [:acceptance]
  ] ++
    case System.get_env("CI_ASSERT_RECEIVE_TIMEOUT_MS") do
      nil -> []
      timeout -> [assert_receive_timeout: String.to_integer(timeout)]
    end

config :ex_unit, ex_unit_config

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :sentry,
  environment_name: :test
