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
##### Domain ##################
###############################

config :domain, ecto_repos: [Domain.Repo]
config :domain, generators: [binary_id: true, context_app: :domain]

config :domain, sql_sandbox: false

config :domain, Domain.Repo,
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "firezone_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: :erlang.system_info(:logical_processors_available) * 2,
  queue_target: 500,
  queue_interval: 1000,
  migration_timestamps: [type: :timestamptz],
  start_apps_before_migration: [:ssl, :logger_json]

config :domain, Domain.Tokens,
  key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5S2",
  salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDej2"

config :domain, Domain.Clients, upstream_dns: ["1.1.1.1"]

config :domain, Domain.Gateways,
  gateway_ipv4_masquerade: true,
  gateway_ipv6_masquerade: true

config :domain, Domain.Telemetry,
  enabled: true,
  id: "firezone-dev"

config :domain, Domain.Auth.Adapters.GoogleWorkspace.APIClient,
  endpoint: "https://admin.googleapis.com",
  finch_transport_opts: []

config :domain, platform_adapter: nil

config :domain, Domain.GoogleCloudPlatform,
  token_endpoint_url:
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
  aggregated_list_endpoint_url:
    "https://compute.googleapis.com/compute/v1/projects/${project_id}/aggregated/instances",
  sign_endpoint_url: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/",
  cloud_storage_url: "https://storage.googleapis.com"

config :domain, Domain.Cluster,
  adapter: nil,
  adapter_config: []

config :domain, Domain.Instrumentation,
  client_logs_enabled: true,
  client_logs_bucket: "logs"

config :domain, :enabled_features,
  traffic_filters: true,
  sign_up: true,
  flow_activities: true,
  self_hosted_relays: true,
  multi_site_resources: true

config :domain, docker_registry: "us-east1-docker.pkg.dev/firezone-staging/firezone"

config :domain, outbound_email_adapter_configured?: false

###############################
##### Web #####################
###############################

config :web, ecto_repos: [Domain.Repo]
config :web, generators: [binary_id: true, context_app: :domain]
config :web, client_handler: "firezone-fd0020211111://"

config :web, Web.Endpoint,
  url: [
    scheme: "http",
    host: "localhost",
    port: 13000,
    path: nil
  ],
  render_errors: [
    formats: [
      html: Web.ErrorHTML,
      json: Web.ErrorJSON,
      xml: Web.ErrorXML
    ],
    layout: false
  ],
  pubsub_server: Domain.PubSub,
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  live_view: [
    signing_salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDejX"
  ]

config :web,
  cookie_secure: false,
  cookie_signing_salt: "WjllcThpb2Y=",
  cookie_encryption_salt: "M0EzM0R6NEMyaw=="

config :web,
  external_trusted_proxies: [],
  private_clients: [%{__struct__: Postgrex.INET, address: {172, 28, 0, 0}, netmask: 16}]

config :web, Web.Plugs.SecureHeaders,
  csp_policy: [
    "default-src 'self' 'nonce-${nonce}'",
    "img-src 'self' data: https://www.gravatar.com",
    "style-src 'self' 'unsafe-inline'"
  ]

config :web, api_url_override: "ws://localhost:13001/"

###############################
##### API #####################
###############################

config :api, ecto_repos: [Domain.Repo]
config :api, generators: [binary_id: true, context_app: :domain]

config :api, API.Endpoint,
  url: [
    scheme: "http",
    host: "localhost",
    port: 13001,
    path: nil
  ],
  render_errors: [
    formats: [json: API.ErrorView],
    layout: false
  ],
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  pubsub_server: Domain.PubSub

config :api,
  cookie_secure: false,
  cookie_signing_salt: "WjllcThpb2Y=",
  cookie_encryption_salt: "M0EzM0R6NEMyaw=="

config :api,
  external_trusted_proxies: [],
  private_clients: [%{__struct__: Postgrex.INET, address: {172, 28, 0, 0}, netmask: 16}]

###############################
##### Third-party configs #####
###############################

config :domain,
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

config :logger, :console,
  level: String.to_atom(System.get_env("LOG_LEVEL", "info")),
  format: "$time $metadata[$level] $message\n",
  metadata: :all

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :web, Web.Mailer,
  adapter: Domain.Mailer.NoopAdapter,
  from_email: "test@firez.one"

# TODO: actually copy fonts here, otherwise:application
# Failed to load resource: the server responded with a status of 404 ()
# source-sans-pro-all-400-normal.woff:1     Failed to load resource: the server responded with a status of 404 ()
config :esbuild,
  version: "0.17.19",
  web: [
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
    cd: Path.expand("../apps/web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.3.2",
  web: [
    args: [
      "--config=tailwind.config.js",
      "--input=css/app.css",
      "--output=tmp/tailwind/app.css"
    ],
    cd: Path.expand("../apps/web/assets", __DIR__)
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
