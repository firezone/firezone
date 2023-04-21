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
  start_apps_before_migration: [:ssl]

config :domain,
  wireguard_ipv4_enabled: true,
  wireguard_ipv4_network: %{__struct__: Postgrex.INET, address: {100, 64, 0, 0}, netmask: 10},
  wireguard_ipv4_address: %{__struct__: Postgrex.INET, address: {100, 64, 0, 1}, netmask: nil},
  wireguard_ipv6_enabled: true,
  wireguard_ipv6_network: %{
    __struct__: Postgrex.INET,
    address: {64768, 0, 0, 0, 0, 0, 0, 0},
    netmask: 106
  },
  wireguard_ipv6_address: %{
    __struct__: Postgrex.INET,
    address: {64768, 0, 0, 0, 0, 0, 0, 1},
    netmask: nil
  },
  wireguard_port: 51_820

config :domain, Domain.Telemetry,
  enabled: true,
  id: "firezone-dev"

config :domain, Domain.ConnectivityChecks,
  http_client_options: [],
  enabled: true,
  interval: 43_200,
  url: "https://ping-dev.firez.one/"

config :domain,
  admin_email: "firezone@localhost",
  default_admin_password: "firezone1234"

config :domain,
  max_devices_per_user: 10

config :domain, Domain.Auth,
  key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDejX",
  max_age: 30 * 60

###############################
##### Web #####################
###############################

config :web, ecto_repos: [Domain.Repo]
config :web, generators: [binary_id: true, context_app: :domain]

config :web,
  external_url: "http://localhost:13000/",
  # TODO: use endpoint path instead?
  path_prefix: "/"

config :web, Web.Endpoint,
  url: [
    scheme: "http",
    host: "localhost",
    port: 13000,
    path: nil
  ],
  render_errors: [
    formats: [html: Web.ErrorHTML, json: Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Domain.PubSub,
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  live_view: [
    signing_salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDejX"
  ]

config :web, Web.SAML,
  entity_id: "urn:firezone.dev:firezone-app",
  certfile_path: Path.expand("../apps/web/priv/cert/saml_selfsigned.pem", __DIR__),
  keyfile_path: Path.expand("../apps/web/priv/cert/saml_selfsigned_key.pem", __DIR__)

config :web,
  cookie_secure: false,
  cookie_signing_salt: "WjllcThpb2Y=",
  cookie_encryption_salt: "M0EzM0R6NEMyaw=="

config :web,
  external_trusted_proxies: [],
  private_clients: [%{__struct__: Postgrex.INET, address: {172, 28, 0, 0}, netmask: 16}]

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
    formats: [json: API.ErrorJSON],
    layout: false
  ],
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  pubsub_server: Domain.PubSub

config :api,
  cookie_secure: false,
  cookie_signing_salt: "WjllcThpb2Y=",
  cookie_encryption_salt: "M0EzM0R6NEMyaw=="

config :api, API.Gateway.Socket,
  key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDejX",
  max_age: 30 * 60

config :api, API.Relay.Socket,
  key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDejX",
  max_age: 30 * 60

###############################
##### Third-party configs #####
###############################

config :logger, :console,
  level: String.to_atom(System.get_env("LOG_LEVEL", "info")),
  format: "$time $metadata[$level] $message\n",
  metadata: :all

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Public API key for telemetry
config :posthog,
  api_url: "https://t.firez.one",
  api_key: "phc_ubuPhiqqjMdedpmbWpG2Ak3axqv5eMVhFDNBaXl9UZK"

# Configures the vault
config :domain, Domain.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      # In AES.GCM, it is important to specify 12-byte IV length for
      # interoperability with other encryption software. See this GitHub
      # issue for more details:
      # https://github.com/danielberkompas/cloak/issues/93
      #
      # In Cloak 2.0, this will be the default iv length for AES.GCM.
      tag: "AES.GCM.V1",
      key: Base.decode64!("XXJ/NGevpvkG9219RYsz21zZWR7CZ//CqA0ARPIBqys="),
      iv_length: 12
    }
  ]

config :web, Web.Mailer,
  adapter: Web.Mailer.NoopAdapter,
  from_email: "test@firez.one"

config :samly, Samly.State, store: Samly.State.Session

config :samly, Samly.Provider,
  idp_id_from: :path_segment,
  service_providers: [],
  identity_providers: []

config :esbuild,
  version: "0.14.41",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.2.4",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/web/assets", __DIR__)
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
