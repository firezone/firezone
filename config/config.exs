import Config

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Public API key for telemetry
config :posthog,
  api_url: "https://t.firez.one",
  api_key: "phc_ubuPhiqqjMdedpmbWpG2Ak3axqv5eMVhFDNBaXl9UZK"

# Guardian configuration
config :fz_http, FzHttpWeb.Auth.HTML.Authentication,
  issuer: "fz_http",
  # Generate with mix guardian.gen.secret
  secret_key: "GApJ4c4a/KJLrBePgTDUk0n67AbjCvI9qdypKZEaJFXl6s9H3uRcIhTt49Fij5UO"

config :fz_http, FzHttpWeb.Auth.JSON.Authentication,
  issuer: "fz_http",
  # Generate with mix guardian.gen.secret
  secret_key: "GApJ4c4a/KJLrBePgTDUk0n67AbjCvI9qdypKZEaJFXl6s9H3uRcIhTt49Fij5UO"

# Use timestamptz for all timestamp fields
config :fz_http, FzHttp.Repo, migration_timestamps: [type: :timestamptz]

config :fz_http,
  http_client_options: [],
  external_trusted_proxies: [],
  private_clients: [],
  sandbox: true,
  wireguard_ipv4_enabled: true,
  wireguard_ipv4_network: "100.64.0.0/10",
  wireguard_ipv4_address: "100.64.0.1",
  wireguard_ipv6_enabled: true,
  wireguard_ipv6_network: "fd00::/106",
  wireguard_ipv6_address: "fd00::1",
  max_devices_per_user: 10,
  telemetry_module: FzCommon.Telemetry,
  supervision_tree_mode: :full,
  http_client: HTTPoison,
  connectivity_checks_enabled: true,
  connectivity_checks_interval: 43_200,
  connectivity_checks_url: "https://ping-dev.firez.one/",
  cookie_secure: true,
  cookie_signing_salt: "WjllcThpb2Y=",
  cookie_encryption_salt: "M0EzM0R6NEMyaw==",
  ecto_repos: [FzHttp.Repo],
  admin_email: "firezone@localhost",
  default_admin_password: "firezone1234",
  server_process_opts: [name: {:global, :fz_http_server}],
  saml_entity_id: "urn:firezone.dev:firezone-app",
  saml_certfile_path: Path.expand("../apps/fz_http/priv/cert/saml_selfsigned.pem", __DIR__),
  saml_keyfile_path: Path.expand("../apps/fz_http/priv/cert/saml_selfsigned_key.pem", __DIR__)

config :fz_wall,
  cli: FzWall.CLI.Sandbox,
  wireguard_ipv4_masquerade: true,
  wireguard_ipv6_masquerade: true,
  server_process_opts: [name: {:global, :fz_wall_server}],
  egress_interface: "dummy",
  wireguard_interface_name: "wg-firezone",
  port_based_rules_supported: true

# This will be changed per-env
config :fz_vpn,
  wireguard_private_key_path: "priv/wg_dev_private_key",
  stats_push_service_enabled: true,
  wireguard_interface_name: "wg-firezone",
  wireguard_port: 51_820,
  wg_adapter: FzVpn.Interface.WGAdapter.Live,
  server_process_opts: [name: {:global, :fz_vpn_server}],
  supervised_children: [FzVpn.Server, FzVpn.StatsPushService]

config :fz_http, FzHttpWeb.Endpoint,
  render_errors: [view: FzHttpWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: FzHttp.PubSub

# Configures Elixir's Logger
config :logger, :console,
  level: String.to_atom(System.get_env("LOG_LEVEL", "info")),
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :remote_ip]

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

config :fz_http, FzHttpWeb.Mailer, adapter: FzHttpWeb.Mailer.NoopAdapter

config :samly, Samly.State, store: Samly.State.Session

config :samly, Samly.Provider,
  idp_id_from: :path_segment,
  service_providers: [],
  identity_providers: []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
