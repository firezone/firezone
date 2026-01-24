# Couple rules:
#
# 1. This file should contain all supported application environment variables,
# even if they are overridden in `runtime.exs`, because it's the main source of
# truth and self-documentation.
#
# 2. The configurations here should be as close to `dev` environment as possible,
# to prevent having too many overrides in other files.
import Config

###############################
##### Portal ##################
###############################

config :portal, ecto_repos: [Portal.Repo, Portal.Repo.Replica]
config :portal, generators: [binary_id: true]

config :portal, sql_sandbox: false
config :portal, replica_repo: Portal.Repo.Replica

# Don't run manual migrations by default
config :portal, run_manual_migrations: false

config :portal, Portal.Repo,
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "firezone_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: :erlang.system_info(:logical_processors_available) * 2,
  queue_target: 500,
  queue_interval: 1000,
  migration_timestamps: [type: :timestamptz],
  migration_lock: :pg_advisory_lock,
  start_apps_before_migration: [:ssl, :logger_json]

config :portal, Portal.Repo.Replica,
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "firezone_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: :erlang.system_info(:logical_processors_available) * 2,
  queue_target: 500,
  queue_interval: 1000

config :portal, Portal.ChangeLogs.ReplicationConnection,
  replication_slot_name: "change_logs_slot",
  publication_name: "change_logs_publication",
  enabled: true,
  connection_opts: [
    hostname: "localhost",
    port: 5432,
    ssl: false,
    parameters: [],
    username: "postgres",
    database: "firezone_dev",
    password: "postgres"
  ],
  # When changing these, make sure to also:
  #   1. Make appropriate changes to `Portal.ChangeLogs.ReplicationConnection`
  #   2. Add tests and test WAL locally
  table_subscriptions: ~w[
    accounts
    memberships
    groups
    actors
    external_identities
    google_auth_providers
    entra_auth_providers
    okta_auth_providers
    oidc_auth_providers
    email_otp_auth_providers
    userpass_auth_providers
    entra_directories
    okta_directories
    google_directories
    clients
    sites
    gateways
    gateway_tokens
    policies
    resources
    client_tokens
    one_time_passcodes
    portal_sessions
    ipv4_addresses
    ipv6_addresses
    api_tokens
  ],
  # Allow up to 5 minutes of processing lag before alerting. This needs to be able to survive
  # deploys without alerting.
  warning_threshold: :timer.minutes(5),

  # We almost never want to bypass changelog inserts
  error_threshold: :timer.hours(30 * 24),

  # Flush change logs data at least every 30 seconds
  flush_interval: :timer.seconds(30),

  # We want to flush at most 500 change logs at a time
  flush_buffer_size: 500

config :portal, Portal.Changes.ReplicationConnection,
  replication_slot_name: "changes_slot",
  publication_name: "changes_publication",
  enabled: true,
  connection_opts: [
    hostname: "localhost",
    port: 5432,
    ssl: false,
    parameters: [],
    username: "postgres",
    database: "firezone_dev",
    password: "postgres"
  ],
  # When changing these, make sure to also:
  #   1. Make appropriate changes to `Portal.Changes.ReplicationConnection`
  #   2. Add an appropriate `Portal.Changes.Hooks` module
  #   3. Add tests and test WAL locally
  table_subscriptions: ~w[
    accounts
    actors
    memberships
    clients
    external_identities
    policy_authorizations
    gateways
    gateway_tokens
    sites
    policies
    resources
    client_tokens
    google_auth_providers
    entra_auth_providers
    okta_auth_providers
    oidc_auth_providers
    email_otp_auth_providers
    userpass_auth_providers
    entra_directories
    okta_directories
    google_directories
    relay_tokens
    portal_sessions
  ],
  # Allow up to 60 seconds of lag before alerting
  warning_threshold: :timer.seconds(60),

  # Allow up to 30 minutes of lag before bypassing hooks
  error_threshold: :timer.minutes(30),

  # Disable flush
  flush_interval: 0,
  flush_buffer_size: 0

config :portal, Portal.Tokens,
  key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5S2",
  salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDej2"

config :portal, Portal.Telemetry,
  metrics_reporter: nil,
  enabled: true

config :portal, Portal.Health,
  health_port: 4000,
  web_endpoint: PortalWeb.Endpoint,
  api_endpoint: PortalAPI.Endpoint,
  # TODO: Remove draining_file_path after Azure migration is complete
  draining_file_path: "/var/run/firezone/draining"

config :portal, Portal.Entra.APIClient,
  client_id: System.get_env("ENTRA_SYNC_CLIENT_ID"),
  client_secret: System.get_env("ENTRA_SYNC_CLIENT_SECRET"),
  endpoint: "https://graph.microsoft.com",
  token_base_url: "https://login.microsoftonline.com",
  # 15 minutes in milliseconds
  req_opts: [receive_timeout: 900_000]

config :portal, Portal.Google.APIClient,
  endpoint: "https://admin.googleapis.com",
  service_account_key: System.get_env("GOOGLE_SERVICE_ACCOUNT_KEY"),
  token_endpoint: "https://oauth2.googleapis.com/token",
  req_opts: [receive_timeout: 60_000]

config :portal, Portal.Google.AuthProvider,
  # Should match an external OAuth2 client in Google Cloud Console
  client_id: System.get_env("GOOGLE_OIDC_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_OIDC_CLIENT_SECRET"),
  response_type: "code",
  scope: "openid email profile",
  discovery_document_uri: "https://accounts.google.com/.well-known/openid-configuration"

config :portal, Portal.Okta.AuthProvider,
  # Should match an external OAuth2 client in Okta
  response_type: "code",
  scope: "openid email profile"

# 15 minutes in milliseconds
config :portal, Portal.Okta.APIClient, req_opts: [receive_timeout: 900_000]

config :portal, Portal.Entra.AuthProvider,
  # Should match an external OAuth2 client in Azure
  client_id: System.get_env("ENTRA_OIDC_CLIENT_ID"),
  client_secret: System.get_env("ENTRA_OIDC_CLIENT_SECRET"),
  response_type: "code",
  scope: "openid email profile",
  # Tenant-scoped endpoint for internal OAuth apps
  discovery_document_uri:
    "https://login.microsoftonline.com/52e801b2-c10e-42e6-9c36-4cb95f3353d5/v2.0/.well-known/openid-configuration"

config :portal, Portal.OIDC.AuthProvider,
  response_type: "code",
  scope: "openid email profile"

config :portal, Portal.Billing.Stripe.APIClient, endpoint: "https://api.stripe.com"

config :portal, Portal.Billing,
  enabled: true,
  secret_key: "sk_test_1111",
  webhook_signing_secret: "whsec_test_1111",
  default_price_id: "price_1OkUIcADeNU9NGxvTNA4PPq6"

config :portal,
  platform_adapter: nil,
  azure_front_door_id: nil

config :portal, Portal.GoogleCloudPlatform,
  metadata_endpoint_url: "http://metadata.google.internal/computeMetadata/v1",
  aggregated_list_endpoint_url:
    "https://compute.googleapis.com/compute/v1/projects/${project_id}/aggregated/instances",
  cloud_metrics_endpoint_url:
    "https://monitoring.googleapis.com/v3/projects/${project_id}/timeSeries",
  sign_endpoint_url: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/",
  cloud_storage_url: "https://storage.googleapis.com"

config :portal, Portal.ComponentVersions,
  firezone_releases_url: "https://www.firezone.dev/api/releases",
  fetch_from_url: true,
  versions: [
    apple: "1.3.8",
    android: "1.3.6",
    gateway: "1.4.0",
    gui: "1.3.11",
    headless: "1.3.5"
  ]

config :portal, Portal.Cluster,
  adapter: nil,
  adapter_config: []

config :portal, :enabled_features,
  idp_sync: true,
  traffic_filters: true,
  sign_up: true,
  policy_conditions: true,
  multi_site_resources: true,
  rest_api: true,
  internet_resource: true

config :portal, sign_up_whitelisted_domains: []

config :portal, docker_registry: "ghcr.io/firezone"

config :portal, outbound_email_adapter_configured?: false

config :portal, relay_presence_topic: "presences:global_relays"

config :portal, web_external_url: "https://localhost:13443"

config :portal, client_handler: "firezone-fd0020211111://"

###############################
##### PortalWeb Endpoint ######
###############################

config :portal, PortalWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [
    scheme: "http",
    host: "localhost",
    port: 13_000,
    path: nil
  ],
  render_errors: [
    formats: [
      html: PortalWeb.ErrorHTML,
      json: PortalWeb.ErrorJSON,
      xml: PortalWeb.ErrorXML
    ],
    layout: false
  ],
  pubsub_server: Portal.PubSub,
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  live_view: [
    signing_salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDejX"
  ]

config :portal,
  api_external_url: "http://localhost:13001"

config :portal,
  cookie_secure: true,
  cookie_signing_salt: "WjllcThpb2Y=",
  cookie_encryption_salt: "M0EzM0R6NEMyaw=="

config :portal,
  external_trusted_proxies: [],
  private_clients: [%{__struct__: Postgrex.INET, address: {172, 28, 0, 0}, netmask: 16}]

config :portal, PortalWeb.Plugs.PutCSPHeader,
  csp_policy: [
    "default-src 'self' 'nonce-${nonce}' https://firezone.statuspage.io",
    "img-src 'self' data: https://www.gravatar.com https://firezone.statuspage.io",
    "style-src 'self' 'unsafe-inline'",
    "script-src 'self' 'unsafe-inline'"
  ]

config :portal, api_url_override: "ws://localhost:13001/"

###############################
##### PortalAPI Endpoint ######
###############################

config :portal, PortalAPI.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [
    scheme: "http",
    host: "localhost",
    port: 13_001,
    path: nil
  ],
  render_errors: [
    formats: [json: PortalAPI.ErrorView],
    layout: false
  ],
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  pubsub_server: Portal.PubSub

config :portal, relays_presence_debounce_timeout_ms: 1_000

config :portal, PortalAPI.RateLimit,
  refill_rate: 10,
  capacity: 200

###############################
##### Third-party configs #####
###############################

config :portal,
  http_client_ssl_opts: []

config :openid_connect,
  finch_transport_opts: []

config :ex_cldr,
  default_locale: "en"

config :mime, :types, %{
  "application/xml" => ["xml"]
}

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :none

config :logger, level: String.to_atom(System.get_env("LOG_LEVEL", "info"))

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: :all

config :phoenix, :json_library, JSON

config :swoosh, :api_client, Swoosh.ApiClient.Req

config :portal, Portal.Mailer,
  adapter: Portal.Mailer.NoopAdapter,
  from_email: "test@firez.one"

config :esbuild,
  version: "0.25.3",
  portal: [
    args: [
      "js/app.js",
      "--bundle",
      "--loader:.woff2=file",
      "--loader:.woff=file",
      "--target=es2017",
      "--outdir=../priv/static/assets",
      "--external:/fonts/*",
      "--external:/images/*"
    ],
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.17",
  portal: [
    args: [
      "--config=tailwind.config.js",
      "--input=css/main.css",
      "--output=../priv/static/assets/main.css"
    ],
    cd: Path.expand("../assets", __DIR__)
  ]

# Base Sentry config
config :sentry,
  before_send: {Portal.Telemetry.Sentry, :before_send},
  # disable Sentry by default, enable in runtime.exs
  dsn: nil,
  environment_name: :unknown,
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]

config :logger_json, encoder: JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
