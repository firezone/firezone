# In this file, we load configuration and secrets
# from environment variables. You can also hardcode secrets,
# although such is generally not recommended and you have to
# remember to add this file to your .gitignore.

import Config

alias FzCommon.{CLI, FzInteger, FzString, FzKernelVersion, FzNet}

# external_url is important, so fail fast here if we can't parse
{:ok, external_url} =
  if config_env() == :prod do
    System.fetch_env!("EXTERNAL_URL")
    |> FzNet.to_complete_url()
  else
    System.get_env("EXTERNAL_URL", "https://localhost")
    |> FzNet.to_complete_url()
  end

%{host: host, path: path, port: port, scheme: scheme} = URI.parse(external_url)

config :fz_http,
  external_url: external_url,
  path_prefix: path

config :fz_http, FzHttpWeb.Endpoint,
  url: [host: host, scheme: scheme, port: port, path: path],
  check_origin: ["//127.0.0.1", "//localhost", "//#{host}"]

config :fz_wall,
  port_based_rules_supported: FzKernelVersion.is_version_greater_than?({5, 6, 8})

# Formerly releases.exs - Only evaluated in production
if config_env() == :prod do
  # For releases, require that all these are set
  admin_email = System.fetch_env!("ADMIN_EMAIL")
  default_admin_password = System.fetch_env!("DEFAULT_ADMIN_PASSWORD")
  guardian_secret_key = System.fetch_env!("GUARDIAN_SECRET_KEY")
  encryption_key = System.fetch_env!("DATABASE_ENCRYPTION_KEY")
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  live_view_signing_salt = System.fetch_env!("LIVE_VIEW_SIGNING_SALT")
  cookie_signing_salt = System.fetch_env!("COOKIE_SIGNING_SALT")
  cookie_encryption_salt = System.fetch_env!("COOKIE_ENCRYPTION_SALT")

  # OPTIONAL

  # telemetry env var name was renamed
  telemetry_id = System.get_env("TELEMETRY_ID", System.get_env("TID", "unknown"))
  telemetry_enabled = FzString.to_boolean(System.get_env("TELEMETRY_ENABLED", "true"))

  wireguard_private_key_path =
    System.get_env("WIREGUARD_PRIVATE_KEY_PATH", "/var/firezone/private_key")

  saml_entity_id = System.get_env("SAML_ENTITY_ID", "urn:firezone.dev:firezone-app")
  saml_keyfile_path = System.get_env("SAML_KEYFILE_PATH", "/var/firezone/saml.key")
  saml_certfile_path = System.get_env("SAML_CERTFILE_PATH", "/var/firezone/saml.crt")
  database_name = System.get_env("DATABASE_NAME", "firezone")
  database_user = System.get_env("DATABASE_USER", "postgres")
  database_host = System.get_env("DATABASE_HOST", "postgres")
  database_port = String.to_integer(System.get_env("DATABASE_PORT", "5432"))
  database_pool = String.to_integer(System.get_env("DATABASE_POOL", "10"))
  database_ssl = FzString.to_boolean(System.get_env("DATABASE_SSL", "false"))
  database_ssl_opts = Jason.decode!(System.get_env("DATABASE_SSL_OPTS", "{}"))
  database_parameters = Jason.decode!(System.get_env("DATABASE_PARAMETERS", "{}"))
  http_client_ssl_opts = Jason.decode!(System.get_env("HTTP_CLIENT_SSL_OPTS", "{}"))
  phoenix_listen_address = System.get_env("PHOENIX_LISTEN_ADDRESS", "0.0.0.0")
  phoenix_port = String.to_integer(System.get_env("PHOENIX_PORT", "13000"))
  external_trusted_proxies = Jason.decode!(System.get_env("EXTERNAL_TRUSTED_PROXIES", "[]"))
  private_clients = Jason.decode!(System.get_env("PRIVATE_CLIENTS", "[]"))
  wireguard_interface_name = System.get_env("WIREGUARD_INTERFACE_NAME", "wg-firezone")
  wireguard_port = String.to_integer(System.get_env("WIREGUARD_PORT", "51820"))
  nft_path = System.get_env("NFT_PATH", "nft")
  egress_interface = System.get_env("EGRESS_INTERFACE", "eth0")
  wireguard_ipv4_enabled = FzString.to_boolean(System.get_env("WIREGUARD_IPV4_ENABLED", "true"))
  wireguard_ipv6_enabled = FzString.to_boolean(System.get_env("WIREGUARD_IPV6_ENABLED", "true"))

  wireguard_ipv4_masquerade =
    FzString.to_boolean(System.get_env("WIREGUARD_IPV4_MASQUERADE", "true"))

  wireguard_ipv6_masquerade =
    FzString.to_boolean(System.get_env("WIREGUARD_IPV6_MASQUERADE", "true"))

  # On fresh installs, these should now be populated in the ENV to be 100.64.0.0/10 and fd00::/106
  wireguard_ipv4_network = System.get_env("WIREGUARD_IPV4_NETWORK", "10.3.2.0/24")
  wireguard_ipv4_address = System.get_env("WIREGUARD_IPV4_ADDRESS", "10.3.2.1")
  wireguard_ipv6_network = System.get_env("WIREGUARD_IPV6_NETWORK", "fd00::3:2:0/120")
  wireguard_ipv6_address = System.get_env("WIREGUARD_IPV6_ADDRESS", "fd00::3:2:1")

  cookie_secure = FzString.to_boolean(System.get_env("SECURE_COOKIES", "true"))

  # Outbound Email
  from_email = System.get_env("OUTBOUND_EMAIL_FROM")

  if from_email do
    provider = System.get_env("OUTBOUND_EMAIL_PROVIDER", "sendmail")

    config :fz_http,
           FzHttpWeb.Mailer,
           [from_email: from_email] ++ FzHttpWeb.Mailer.configs_for(provider)
  end

  max_devices_per_user =
    System.get_env("MAX_DEVICES_PER_USER", "10")
    |> String.to_integer()
    |> FzInteger.clamp(0, 100)

  telemetry_module =
    if telemetry_enabled do
      FzCommon.Telemetry
    else
      FzCommon.MockTelemetry
    end

  connectivity_checks_enabled =
    FzString.to_boolean(System.get_env("CONNECTIVITY_CHECKS_ENABLED", "true")) &&
      System.get_env("CI") != "true"

  connectivity_checks_interval =
    System.get_env("CONNECTIVITY_CHECKS_INTERVAL", "3600")
    |> String.to_integer()
    |> FzInteger.clamp(60, 86_400)

  # Password is not needed if using bundled PostgreSQL, so use nil if it's not set.
  database_password = System.get_env("DATABASE_PASSWORD")

  parameters = Keyword.new(database_parameters, fn {k, v} -> {String.to_atom(k), v} end)

  # Database configuration
  connect_opts = [
    database: database_name,
    username: database_user,
    hostname: database_host,
    port: database_port,
    pool_size: database_pool,
    ssl: database_ssl,
    ssl_opts: FzCommon.map_ssl_opts(database_ssl_opts),
    parameters: parameters,
    queue_target: 500
  ]

  if database_password do
    config(:fz_http, FzHttp.Repo, connect_opts ++ [password: database_password])
  else
    config(:fz_http, FzHttp.Repo, connect_opts)
  end

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
        tag: "AES.GCM.V1", key: Base.decode64!(encryption_key), iv_length: 12
      }
    ]

  listen_ip =
    phoenix_listen_address
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()

  config :fz_http, FzHttpWeb.Endpoint,
    http: [ip: listen_ip, port: phoenix_port],
    server: true,
    secret_key_base: secret_key_base,
    live_view: [
      signing_salt: live_view_signing_salt
    ]

  config :fz_wall,
    wireguard_ipv4_masquerade: wireguard_ipv4_masquerade,
    wireguard_ipv6_masquerade: wireguard_ipv6_masquerade,
    nft_path: nft_path,
    egress_interface: egress_interface,
    wireguard_interface_name: wireguard_interface_name,
    cli: FzWall.CLI.Live

  config :fz_vpn,
    wireguard_private_key_path: wireguard_private_key_path,
    wireguard_interface_name: wireguard_interface_name,
    wireguard_port: wireguard_port

  # Guardian configuration
  # XXX: Use different secret keys here when config / secret generation is refactored
  config :fz_http, FzHttpWeb.Auth.HTML.Authentication,
    issuer: "fz_http",
    secret_key: guardian_secret_key

  config :fz_http, FzHttpWeb.Auth.JSON.Authentication,
    issuer: "fz_http",
    secret_key: guardian_secret_key

  config :fz_http,
    http_client_options: [ssl: FzCommon.map_ssl_opts(http_client_ssl_opts)],
    saml_entity_id: saml_entity_id,
    saml_certfile_path: saml_certfile_path,
    saml_keyfile_path: saml_keyfile_path,
    external_trusted_proxies: external_trusted_proxies,
    private_clients: private_clients,
    cookie_signing_salt: cookie_signing_salt,
    cookie_encryption_salt: cookie_encryption_salt,
    cookie_secure: cookie_secure,
    max_devices_per_user: max_devices_per_user,
    wireguard_ipv4_enabled: wireguard_ipv4_enabled,
    wireguard_ipv4_network: wireguard_ipv4_network,
    wireguard_ipv4_address: wireguard_ipv4_address,
    wireguard_ipv6_enabled: wireguard_ipv6_enabled,
    wireguard_ipv6_network: wireguard_ipv6_network,
    wireguard_ipv6_address: wireguard_ipv6_address,
    telemetry_module: telemetry_module,
    telemetry_id: telemetry_id,
    connectivity_checks_enabled: connectivity_checks_enabled,
    connectivity_checks_interval: connectivity_checks_interval,
    admin_email: admin_email,
    default_admin_password: default_admin_password

  # Configure OpenID Connect
  config :openid_connect,
    http_client_options: [ssl: FzCommon.map_ssl_opts(http_client_ssl_opts)]

  # Configure strategies
  identity_strategy =
    {:identity,
     {Ueberauth.Strategy.Identity,
      [
        callback_methods: ["POST"],
        callback_url: "#{external_url}/auth/identity/callback",
        uid_field: :email
      ]}}

  # Local auth can be disabled at runtime. We check for that in multiple
  # places to ensure this strategy is noop'd when local_auth_enabled = false
  # without having to conditionally reconfigure Ueberauth strategies.
  #
  # Local auth is likely to removed in the future, so it's not worth
  # refactoring this.
  config :ueberauth, Ueberauth, providers: identity_strategy
end
