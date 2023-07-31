import Config

if config_env() == :prod do
  import Domain.Config, only: [compile_config!: 1]

  ###############################
  ##### Domain ##################
  ###############################

  config :domain, Domain.Repo,
    database: compile_config!(:database_name),
    username: compile_config!(:database_user),
    hostname: compile_config!(:database_host),
    port: compile_config!(:database_port),
    password: compile_config!(:database_password),
    pool_size: compile_config!(:database_pool_size),
    ssl: compile_config!(:database_ssl_enabled),
    ssl_opts: compile_config!(:database_ssl_opts),
    parameters: compile_config!(:database_parameters),
    show_sensitive_data_on_connection_error: false

  external_url = compile_config!(:external_url)

  %{
    scheme: external_url_scheme,
    host: external_url_host,
    port: external_url_port,
    path: external_url_path
  } = URI.parse(external_url)

  config :domain, Domain.Devices, upstream_dns: compile_config!(:devices_upstream_dns)

  config :domain, Domain.Gateways,
    gateway_ipv4_masquerade: compile_config!(:gateway_ipv4_masquerade),
    gateway_ipv6_masquerade: compile_config!(:gateway_ipv6_masquerade),
    key_base: compile_config!(:gateways_auth_token_key_base),
    salt: compile_config!(:gateways_auth_token_salt)

  config :domain, Domain.Relays,
    key_base: compile_config!(:relays_auth_token_key_base),
    salt: compile_config!(:relays_auth_token_salt)

  config :domain, Domain.Telemetry,
    enabled: compile_config!(:telemetry_enabled),
    id: compile_config!(:telemetry_id)

  config :domain, Domain.Auth,
    key_base: compile_config!(:auth_token_key_base),
    salt: compile_config!(:auth_token_salt)

  config :domain, Domain.Auth.Adapters.GoogleWorkspace.APIClient,
    finch_transport_opts: compile_config!(:http_client_ssl_opts)

  ###############################
  ##### Web #####################
  ###############################

  config :web, Web.Endpoint,
    http: [
      ip: compile_config!(:phoenix_listen_address).address,
      port: compile_config!(:phoenix_http_web_port),
      protocol_options: compile_config!(:phoenix_http_protocol_options)
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
    ]

  config :web,
    external_trusted_proxies: compile_config!(:phoenix_external_trusted_proxies),
    private_clients: compile_config!(:phoenix_private_clients)

  config :web,
    cookie_secure: compile_config!(:phoenix_secure_cookies),
    cookie_signing_salt: compile_config!(:cookie_signing_salt),
    cookie_encryption_salt: compile_config!(:cookie_encryption_salt)

  ###############################
  ##### API #####################
  ###############################

  config :api, API.Endpoint,
    http: [
      ip: compile_config!(:phoenix_listen_address).address,
      port: compile_config!(:phoenix_http_api_port),
      protocol_options: compile_config!(:phoenix_http_protocol_options)
    ],
    url: [
      scheme: external_url_scheme,
      host: external_url_host,
      port: external_url_port,
      path: external_url_path
    ],
    secret_key_base: compile_config!(:secret_key_base)

  config :api,
    cookie_secure: compile_config!(:phoenix_secure_cookies),
    cookie_signing_salt: compile_config!(:cookie_signing_salt),
    cookie_encryption_salt: compile_config!(:cookie_encryption_salt)

  config :api,
    external_trusted_proxies: compile_config!(:phoenix_external_trusted_proxies),
    private_clients: compile_config!(:phoenix_private_clients)

  ###############################
  ##### Erlang Cluster ##########
  ###############################

  config :domain, Domain.Cluster,
    adapter: compile_config!(:erlang_cluster_adapter),
    adapter_config: compile_config!(:erlang_cluster_adapter_config)

  ###############################
  ##### Third-party configs #####
  ###############################

  if System.get_env("OTLP_ENDPOINT") do
    config :opentelemetry,
      traces_exporter: :otlp

    config :opentelemetry_exporter,
      otlp_protocol: :http_protobuf,
      otlp_endpoint: System.get_env("OTLP_ENDPOINT")
  end

  config :domain,
    http_client_ssl_opts: compile_config!(:http_client_ssl_opts)

  config :openid_connect,
    finch_transport_opts: compile_config!(:http_client_ssl_opts)

  config :web,
         Web.Mailer,
         [
           adapter: compile_config!(:outbound_email_adapter),
           from_email: compile_config!(:outbound_email_from)
         ] ++ compile_config!(:outbound_email_adapter_opts)
end
