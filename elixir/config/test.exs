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

database = "#{System.get_env("DATABASE_NAME", "firezone")}_test#{partition_suffix}"

config :portal, sql_sandbox: true

config :portal, run_manual_migrations: true

config :portal, Portal.Repo,
  database: database,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  queue_target: 1000

for repo <- [
      Portal.Repo.Web,
      Portal.Repo.Api,
      Portal.Repo.Job,
      Portal.Repo.Poller
    ] do
  config :portal, repo,
    database: database,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 5,
    queue_target: 1000
end

# Directory locks are session state taken from a second session, so the lock
# pool stays out of the sandbox
config :portal, Portal.Repo.Lock,
  database: database,
  pool_size: 10,
  queue_target: 1000

# Oban has its own config validation that prevents overriding config in runtime.exs,
# so we explicitly set the config in dev.exs, test.exs, and runtime.exs (for prod) only.
config :portal, Oban,
  notifier: Oban.Notifiers.PG,
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

config :portal, Portal.ChangeLogs.Consumer,
  replication_slot_name: "test_change_logs_slot",
  publication_name: "test_change_logs_publication",
  enabled: false

config :portal, Portal.Changes.Consumer,
  replication_slot_name: "test_changes_slot",
  publication_name: "test_changes_publication",
  enabled: false

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

config :portal, Portal.Splunk.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.Splunk.APIClient},
    retry: false
  ]

config :portal, Portal.Datadog.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.Datadog.APIClient},
    retry: false
  ]

config :portal, Portal.NewRelic.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.NewRelic.APIClient},
    retry: false
  ]

config :portal, Portal.Elastic.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.Elastic.APIClient},
    retry: false
  ]

config :portal, Portal.Sentinel.APIClient,
  client_id: "test_sentinel_client_id",
  client_secret: "test_sentinel_client_secret",
  token_base_url: "https://login.microsoftonline.com",
  req_opts: [
    plug: {Req.Test, Portal.Sentinel.APIClient},
    retry: false
  ]
config :portal, Portal.S3.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.S3.APIClient},
    retry: false
  ],
  access_key_id: "test-aws-access-key-id",
  secret_access_key: "test-aws-secret-access-key",
  aws_account_id: "123456789012"

config :portal, Portal.QRadar.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.QRadar.APIClient},
    retry: false
  ]

config :portal, Portal.HTTP.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.HTTP.APIClient},
    retry: false
  ]

config :portal, Portal.LogSinks.Delivery, visibility_lag_seconds: 0

config :portal, Portal.Azure.ManagedIdentity,
  client_id: "test-azure-client-id",
  req_opts: [
    plug: {Req.Test, Portal.Azure.ManagedIdentity},
    retry: false
  ]

config :portal, Portal.Microsoft.Graph.APIClient,
  endpoint: "https://graph.microsoft.com",
  token_base_url: "https://login.microsoftonline.com",
  applications: [
    entra: [client_id: "test_client_id", client_secret: "test_client_secret"],
    intune: [client_id: "test_intune_client_id", client_secret: "test_intune_client_secret"]
  ],
  req_opts: [
    plug: {Req.Test, Portal.Microsoft.Graph.APIClient},
    retry: false
  ]

config :portal, Portal.Defender.APIClient,
  endpoint: "https://api.security.microsoft.com",
  token_base_url: "https://login.microsoftonline.com",
  token_scope: "https://api.securitycenter.microsoft.com/.default",
  client_id: "test_defender_client_id",
  client_secret: "test_defender_client_secret",
  req_opts: [
    plug: {Req.Test, Portal.Defender.APIClient},
    retry: false
  ]

config :portal, Portal.Iru.APIClient,
  api_domains: [us: "api.kandji.io", eu: "api.eu.kandji.io"],
  req_opts: [
    plug: {Req.Test, Portal.Iru.APIClient},
    retry: false
  ]

config :portal, Portal.Santa.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.Santa.APIClient},
    retry: false
  ]

config :portal, Portal.SentinelOne.APIClient,
  req_opts: [
    plug: {Req.Test, Portal.SentinelOne.APIClient},
    retry: false
  ]

config :portal, Portal.Workers.SyncErrorNotification, []

config :portal, Portal.Workers.LogSinkErrorNotification, []

config :portal, Portal.Telemetry, enabled: false

config :opentelemetry_experimental, sdk_disabled: true

config :portal, Portal.ConnectivityChecks, enabled: false
config :portal, Portal.ClockDriftAlarm, enabled: false
config :portal, :client_session_queue, enabled: false
config :portal, :gateway_session_queue, enabled: false
config :portal, :policy_authorization_queue, enabled: false
config :portal, :revocation_endpoint_queue, enabled: false

config :portal, Portal.ComponentVersions,
  fetch_from_url: false,
  req_opts: [
    plug: {Req.Test, Portal.ComponentVersions},
    retry: false
  ],
  versions: [
    apple: "1.0.0",
    android: "1.0.0",
    gateway: "1.0.0",
    gui: "1.0.0",
    headless: "1.0.0"
  ]

config :portal, Portal.Google.APIClient,
  # Never inherit a developer's real Google credentials from the shell
  # config/config.exs reads these from env, and tests must control them
  # explicitly via put_env_override/3.
  service_account_key: nil,
  service_account_email: nil,
  workload_identity_provider: nil,
  workload_identity_audience: nil,
  req_opts: [
    retry: false,
    plug: {Req.Test, Portal.Google.APIClient}
  ]

config :portal, Portal.Crl.Sync,
  req_opts: [
    retry: false,
    plug: {Req.Test, Portal.Crl.Sync}
  ]

config :portal, Portal.OAuth.ClientMetadata,
  req_opts: [
    retry: false,
    plug: {Req.Test, Portal.OAuth.ClientMetadata}
  ],
  # Req.Test never connects, but the mandatory protection still resolves before
  # handing a request to its adapter. Use a known-public answer so metadata
  # tests can keep descriptive fake hostnames (and localhost origin fixtures).
  ssrf_protection_opts: [
    resolver: fn
      _host, :inet -> {:ok, [{8, 8, 8, 8}]}
      _host, :inet6 -> {:error, :nxdomain}
    end
  ]

config :portal, Portal.Ocsp.Sync,
  req_opts: [
    retry: false,
    plug: {Req.Test, Portal.Ocsp.Sync}
  ]

config :portal, Portal.TokenCache, enabled: false

# Auth provider configs with Req.Test for OIDC mocking
config :portal, Portal.Google.AuthProvider,
  req_opts: [
    retry: false,
    plug: {Req.Test, PortalWeb.OIDC}
  ]

config :portal, Portal.Google.SyncAuthorization,
  client_id: "test_google_sync_authz_client_id",
  client_secret: "test_google_sync_authz_client_secret",
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

# Keep the endpoint limiter effectively disabled in general tests to avoid
# cross-test interference from shared localhost IPs. Dedicated rate-limit tests
# override this config with strict values.
config :portal, PortalWeb.RateLimit,
  refill_rate: 100_000,
  capacity: 1_000_000

# MCP controller tests share the loopback source IP, so dedicated limiter tests
# pass strict values directly while the general suite uses a practically
# unbounded bucket.
config :portal, PortalAPI.Plugs.MCPRateLimit,
  refill_rate: 100_000,
  capacity: 1_000_000

# The ingestion endpoint defaults to a strict 1 req/s per IP; keep it effectively
# disabled in general tests (which share localhost) to avoid cross-test 429s.
# Dedicated rate-limit tests pass strict opts directly to the plug instead.
config :portal, PortalAPI.Plugs.IngestionRateLimit,
  refill_rate: 100_000,
  capacity: 1_000_000

config :portal, PortalWeb.Plugs.PutSecurityHeaders,
  csp_policy: [
    "default-src 'self' https://firezone.statuspage.io",
    "img-src 'self' data: https://www.gravatar.com https://firezone.statuspage.io",
    "style-src 'self'",
    "script-src 'self' 'nonce-${nonce}'",
    "object-src 'none'",
    "base-uri 'self'",
    "frame-ancestors 'none'"
  ]

config :portal, :constant_execution_time, 1

###############################
##### PortalAPI Endpoint ######
###############################

# Use ephemeral port for HTTP server to avoid conflicts between test runs
config :portal, PortalAPI.Endpoint,
  http: [port: 0],
  url: [port: 13_101],
  server: true

# Use ephemeral port for HTTP server to avoid conflicts between test runs
config :portal, PortalOps.Endpoint,
  http: [port: 0],
  url: [port: 13_102],
  server: true

# shorten debounce timeout for tests
config :portal, relays_presence_debounce_timeout_ms: 100

###############################
##### Third-party configs #####
###############################
config :portal, Portal.Mailer, adapter: Portal.Mailer.TestAdapter
config :portal, Portal.Mailer.Secondary, adapter: Portal.Mailer.TestAdapter

# Disable HTTP retries so error-path OIDC tests don't back off and retry
config :portal, OpenIDConnect, retry: false

# Allow asserting on info logs and higher
config :logger, level: :info

config :argon2_elixir, t_cost: 1, m_cost: 8

config :geolix,
  databases: [
    %{id: :city, adapter: Portal.Test.GeoAdapter, data: %{}}
  ]

default_assert_receive_timeout = 1_000

assert_receive_timeout =
  case System.get_env("CI_ASSERT_RECEIVE_TIMEOUT_MS") do
    nil -> default_assert_receive_timeout
    timeout -> max(String.to_integer(timeout), default_assert_receive_timeout)
  end

ex_unit_config = [
  formatters: [JUnitFormatter, ExUnit.CLIFormatter],
  capture_log: true,
  assert_receive_timeout: assert_receive_timeout
]

config :ex_unit, ex_unit_config

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :sentry,
  environment_name: :test
