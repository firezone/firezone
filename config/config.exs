# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# *Note*:
# This configuration is generated on compile time. To configure the application during runtime,
# use releases.exs. These configuration options are overridden by environment-specific
# configuration files.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

require Logger

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Public API key for telemetry
config :posthog,
  api_url: "https://telemetry.firez.one",
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

config :fz_http,
  external_trusted_proxies: [],
  private_clients: [],
  disable_vpn_on_oidc_error: true,
  sandbox: true,
  allow_unprivileged_device_management: true,
  allow_unprivileged_device_configuration: true,
  telemetry_id: "543aae08-5a2b-428d-b704-2956dd3f5a57",
  wireguard_ipv4_enabled: true,
  wireguard_ipv4_network: "10.3.2.0/24",
  wireguard_ipv4_address: "10.3.2.1",
  wireguard_ipv6_enabled: true,
  wireguard_ipv6_network: "fd00::3:2:0/120",
  wireguard_ipv6_address: "fd00::3:2:1",
  max_devices_per_user: 10,
  telemetry_module: FzCommon.Telemetry,
  supervision_tree_mode: :full,
  http_client: HTTPoison,
  connectivity_checks_enabled: true,
  connectivity_checks_interval: 3_600,
  connectivity_checks_url: "https://ping-dev.firez.one/",
  cookie_secure: true,
  cookie_signing_salt: "Z9eq8iof",
  cookie_encryption_salt: "3A33Dz4C2k",
  ecto_repos: [FzHttp.Repo],
  admin_email: "firezone@localhost",
  default_admin_password: "firezone1234",
  server_process_opts: [name: {:global, :fz_http_server}],
  openid_connect_providers: "{}",
  saml_identity_providers: %{},
  saml_entity_id: "urn:firezone.dev:firezone-app",
  saml_certfile_path: "apps/fz_http/priv/cert/saml_selfsigned.pem",
  saml_keyfile_path: "apps/fz_http/priv/cert/saml_selfsigned_key.pem",
  openid_connect: OpenIDConnect

config :fz_wall,
  cli: FzWall.CLI.Sandbox,
  wireguard_ipv4_masquerade: true,
  wireguard_ipv6_masquerade: true,
  server_process_opts: [name: {:global, :fz_wall_server}],
  egress_interface: "dummy",
  wireguard_interface_name: "wg-firezone",
  port_based_rules_supported: true

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 4, cleanup_interval_ms: 60_000 * 10]}

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
