# TODO: probably we don't want to resolve Application environment in Resolve,
# because then it will just read previously defined values in runtime.exs
import Config

if Mix.env() == :prod do
  import FzHttp.Config, only: [compile_config!: 1]

  config :fz_http, FzHttp.Repo,
    database: compile_config!(:database_name),
    username: compile_config!(:database_user),
    hostname: compile_config!(:database_host),
    port: compile_config!(:database_port),
    password: compile_config!(:database_password),
    pool_size: compile_config!(:database_pool_size),
    ssl: compile_config!(:database_ssl_enabled),
    ssl_opts: compile_config!(:database_ssl_opts),
    parameters: compile_config!(:database_parameters)

  external_url = compile_config!(:external_url)

  %{
    scheme: external_url_scheme,
    host: external_url_host,
    port: external_url_port,
    path: external_url_path
  } = URI.parse(external_url)

  config :fz_http,
    external_url: external_url,
    path_prefix: external_url_path

  config :fz_http, FzHttpWeb.Endpoint,
    server: true,
    http: [
      ip: compile_config!(:phoenix_listen_address).address,
      port: compile_config!(:phoenix_port)
    ],
    url: [
      scheme: external_url_scheme,
      host: external_url_host,
      port: external_url_port,
      path: external_url_path
    ],
    secret_key_base: compile_config!(:secret_key_base),
    live_view: [
      signing_salt: compile_config!(:live_view_signing_salt)
    ],
    check_origin: ["//127.0.0.1", "//localhost", "//#{external_url_host}"]

  config :fz_http,
    wireguard_ipv4_enabled: compile_config!(:wireguard_ipv4_enabled),
    wireguard_ipv4_network: compile_config!(:wireguard_ipv4_network),
    wireguard_ipv4_address: compile_config!(:wireguard_ipv4_address),
    wireguard_ipv6_enabled: compile_config!(:wireguard_ipv6_enabled),
    wireguard_ipv6_network: compile_config!(:wireguard_ipv6_network),
    wireguard_ipv6_address: compile_config!(:wireguard_ipv6_address)

  config :fz_http,
    saml_entity_id: compile_config!(:saml_entity_id),
    saml_certfile_path: compile_config!(:saml_certfile_path),
    saml_keyfile_path: compile_config!(:saml_keyfile_path)

  config :fz_http,
    external_trusted_proxies: compile_config!(:phoenix_external_trusted_proxies),
    private_clients: compile_config!(:phoenix_private_clients)

  config :fz_http,
    telemetry_id: compile_config!(:telemetry_id),
    telemetry_module: compile_config!(:telemetry_module)

  config :fz_http,
    cookie_secure: compile_config!(:phoenix_secure_cookies),
    cookie_signing_salt: compile_config!(:cookie_signing_salt),
    cookie_encryption_salt: compile_config!(:cookie_encryption_salt)

  config :fz_http,
    http_client_options: compile_config!(:http_client_ssl_opts),
    connectivity_checks_enabled: compile_config!(:connectivity_checks_enabled),
    connectivity_checks_interval: compile_config!(:connectivity_checks_interval)

  config :fz_http,
    admin_email: compile_config!(:default_admin_email),
    default_admin_password: compile_config!(:default_admin_password)

  config :fz_http,
    max_devices_per_user: compile_config!(:max_devices_per_user)

  ###############################
  ##### FZ Firewall configs #####
  ###############################

  config :fz_wall, cli: FzWall.CLI.Live

  config :fz_wall,
    wireguard_ipv4_masquerade: compile_config!(:wireguard_ipv4_masquerade),
    wireguard_ipv6_masquerade: compile_config!(:wireguard_ipv6_masquerade),
    wireguard_interface_name: compile_config!(:wireguard_interface_name),
    nft_path: compile_config!(:gateway_nft_path),
    egress_interface: compile_config!(:gateway_egress_interface)

  config :fz_wall,
    port_based_rules_supported:
      :os.version()
      |> Tuple.to_list()
      |> Enum.join(".")
      |> Version.match?("> 5.6.8")

  ###############################
  ##### FZ VPN configs ##########
  ###############################

  config :fz_vpn,
    wireguard_private_key_path: compile_config!(:wireguard_private_key_path),
    wireguard_interface_name: compile_config!(:wireguard_interface_name),
    wireguard_port: compile_config!(:wireguard_port)

  ###############################
  ##### Third-party configs #####
  ###############################

  config :fz_http, FzHttpWeb.Auth.HTML.Authentication,
    secret_key: compile_config!(:guardian_secret_key)

  config :fz_http, FzHttpWeb.Auth.JSON.Authentication,
    secret_key: compile_config!(:guardian_secret_key)

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
        key: Base.decode64!(compile_config!(:database_encryption_key)),
        iv_length: 12
      }
    ]

  config :openid_connect,
    finch_transport_opts: compile_config!(:http_client_ssl_opts)

  config :ueberauth, Ueberauth,
    providers: [
      identity:
        {Ueberauth.Strategy.Identity,
         callback_methods: ["POST"],
         callback_url: "#{external_url}/auth/identity/callback",
         uid_field: :email}
    ]

  config :fz_http,
         FzHttpWeb.Mailer,
         [
           adapter: compile_config!(:outbound_email_adapter),
           from_email: compile_config!(:outbound_email_from)
         ] ++ compile_config!(:outbound_email_adapter_opts)
end
