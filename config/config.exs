# Couple rules:
#
# 1. This file should contain all supported application environment variables,
# even if they are overriden in `runtime.exs`, because it's the main source of
# truth and self-documentation.
#
# 2. The configurations here should be as close to `dev` environment as possible,
# to prevent having too many overrides in other files.
import Config

config :fz_http, supervision_tree_mode: :full

config :fz_http, ecto_repos: [FzHttp.Repo]
config :fz_http, sql_sandbox: false

config :fz_http, FzHttp.Repo,
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "firezone_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  queue_target: 100,
  queue_interval: 2000,
  migration_timestamps: [type: :timestamptz]

config :fz_http,
  external_url: "http://localhost:13000/",
  path_prefix: "/"

config :fz_http, FzHttpWeb.Endpoint,
  url: [
    scheme: "http",
    host: "localhost",
    port: 13000,
    path: nil
  ],
  render_errors: [view: FzHttpWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: FzHttp.PubSub,
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  live_view: [
    signing_salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDejX"
  ]

config :fz_http,
  wireguard_ipv4_enabled: true,
  wireguard_ipv4_network: "100.64.0.0/10",
  wireguard_ipv4_address: "100.64.0.1",
  wireguard_ipv6_enabled: true,
  wireguard_ipv6_network: "fd00::/106",
  wireguard_ipv6_address: "fd00::1"

config :fz_http,
  saml_entity_id: "urn:firezone.dev:firezone-app",
  saml_certfile_path: Path.expand("../apps/fz_http/priv/cert/saml_selfsigned.pem", __DIR__),
  saml_keyfile_path: Path.expand("../apps/fz_http/priv/cert/saml_selfsigned_key.pem", __DIR__)

config :fz_http,
  external_trusted_proxies: [],
  private_clients: ["172.28.0.0/16"]

config :fz_http,
  telemetry_id: "firezone-dev",
  telemetry_module: FzCommon.MockTelemetry

config :fz_http,
  cookie_secure: false,
  cookie_signing_salt: "WjllcThpb2Y=",
  cookie_encryption_salt: "M0EzM0R6NEMyaw=="

config :fz_http,
  http_client: HTTPoison,
  http_client_options: [],
  connectivity_checks_enabled: true,
  connectivity_checks_interval: 43_200,
  connectivity_checks_url: "https://ping-dev.firez.one/"

config :fz_http,
  admin_email: "firezone@localhost",
  default_admin_password: "firezone1234"

config :fz_http,
  max_devices_per_user: 10

###############################
##### FZ Firewall configs #####
###############################

config :fz_wall, cli: FzWall.CLI.Sandbox

config :fz_wall,
  wireguard_ipv4_masquerade: true,
  wireguard_ipv6_masquerade: true,
  wireguard_interface_name: "wg-firezone",
  nft_path: "nft",
  egress_interface: "dummy"

config :fz_wall,
  port_based_rules_supported: true

###############################
##### FZ VPN configs ##########
###############################

# This will be changed per-env
config :fz_vpn,
  wireguard_private_key_path: "priv/wg_dev_private_key",
  stats_push_service_enabled: true,
  wireguard_interface_name: "wg-firezone",
  wireguard_port: 51_820,
  wg_adapter: FzVpn.Interface.WGAdapter.Live,
  supervised_children: [FzVpn.Server, FzVpn.StatsPushService]

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

config :ueberauth, Ueberauth,
  providers: [
    identity: {Ueberauth.Strategy.Identity, callback_methods: ["POST"], uid_field: :email}
  ]

# Guardian configuration
config :fz_http, FzHttpWeb.Auth.HTML.Authentication,
  issuer: "fz_http",
  # Generate with mix guardian.gen.secret
  secret_key: "GApJ4c4a/KJLrBePgTDUk0n67AbjCvI9qdypKZEaJFXl6s9H3uRcIhTt49Fij5UO"

config :fz_http, FzHttpWeb.Auth.JSON.Authentication,
  issuer: "fz_http",
  # Generate with mix guardian.gen.secret
  secret_key: "GApJ4c4a/KJLrBePgTDUk0n67AbjCvI9qdypKZEaJFXl6s9H3uRcIhTt49Fij5UO"

# Configures the vault
config :fz_http, FzHttp.Vault,
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

config :fz_http, FzHttpWeb.Mailer,
  adapter: FzHttpWeb.Mailer.NoopAdapter,
  from_email: "test@firez.one"

config :samly, Samly.State, store: Samly.State.Session

config :samly, Samly.Provider,
  idp_id_from: :path_segment,
  service_providers: [],
  identity_providers: []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
