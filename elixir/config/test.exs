import Config

###############################
##### Domain ##################
###############################

partition_suffix =
  if partition = System.get_env("MIX_TEST_PARTITION") do
    "_p#{partition}"
  else
    ""
  end

config :domain, sql_sandbox: true

config :domain, run_manual_migrations: true

config :domain, Domain.Repo,
  database: "firezone_test#{partition_suffix}",
  pool: Ecto.Adapters.SQL.Sandbox,
  queue_target: 1000

# Oban has its own config validation that prevents overriding config in runtime.exs,
# so we explicitly set the config in dev.exs, test.exs, and runtime.exs (for prod) only.
config :domain, Oban,
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
    #    {"* * * * *", Domain.Workers.DeleteExpiredPolicyAuthorizations}
    #  ]}
  ],
  queues: [default: 10],
  engine: Oban.Engines.Basic,
  repo: Domain.Repo

config :domain, Domain.ChangeLogs.ReplicationConnection,
  replication_slot_name: "test_change_logs_slot",
  publication_name: "test_change_logs_publication",
  enabled: false,
  connection_opts: [
    database: "firezone_test#{partition_suffix}"
  ]

config :domain, Domain.Changes.ReplicationConnection,
  replication_slot_name: "test_changes_slot",
  publication_name: "test_changes_publication",
  enabled: false,
  connection_opts: [
    database: "firezone_test#{partition_suffix}"
  ]

config :domain, Domain.Billing.Stripe.APIClient,
  endpoint: "https://api.stripe.com",
  finch_transport_opts: [],
  retry_config: [
    max_retries: 3,
    base_delay_ms: 100,
    max_delay_ms: 1000
  ]

config :domain, Domain.Telemetry, enabled: false

config :domain, Domain.ConnectivityChecks, enabled: false

config :domain, platform_adapter: Domain.GoogleCloudPlatform

config :domain, Domain.GoogleCloudPlatform, service_account_email: "foo@iam.example.com"

config :domain, Domain.ComponentVersions,
  fetch_from_url: false,
  versions: [
    apple: "1.0.0",
    android: "1.0.0",
    gateway: "1.0.0",
    gui: "1.0.0",
    headless: "1.0.0"
  ]

config :domain, Domain.Telemetry.Reporter.GoogleCloudMetrics, project_id: "fz-test"

config :domain, web_external_url: "http://localhost:13100"

# Prevent Oban from running jobs and plugins in tests
config :domain, Oban, testing: :manual

###############################
##### Web #####################
###############################

config :web, Web.Endpoint,
  http: [port: 13_100],
  url: [port: 13_100],
  server: true

config :web, Web.Plugs.SecureHeaders,
  csp_policy: [
    "default-src 'self' 'nonce-${nonce}' https://firezone.statuspage.io",
    "img-src 'self' data: https://www.gravatar.com https://firezone.statuspage.io",
    "style-src 'self' 'unsafe-inline'",
    "script-src 'self' 'unsafe-inline'"
  ]

config :web, :constant_execution_time, 1

###############################
##### API #####################
###############################

config :api, API.Endpoint,
  http: [port: 13_101],
  url: [port: 13_101],
  server: true

config :api,
  # shorten debounce timeout for tests
  relays_presence_debounce_timeout_ms: 100

###############################
##### Third-party configs #####
###############################
config :domain, Domain.Mailer, adapter: Domain.Mailer.TestAdapter

# Allow asserting on info logs and higher
config :logger, level: :info

config :argon2_elixir, t_cost: 1, m_cost: 8

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

config :workos, WorkOS.Client,
  api_key: "sk_example_123456789",
  client_id: "client_123456789"

config :sentry,
  environment_name: :test
