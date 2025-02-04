import Config

if config_env() == :prod do
  import Domain.Config, only: [compile_config!: 1, compile_config: 1]

  ###############################
  ##### Domain ##################
  ###############################

  config :domain,
         Domain.Repo,
         [
           {:database, compile_config!(:database_name)},
           {:username, compile_config!(:database_user)},
           {:port, compile_config!(:database_port)},
           {:pool_size, compile_config!(:database_pool_size)},
           {:ssl, compile_config!(:database_ssl_enabled)},
           {:ssl_opts, compile_config!(:database_ssl_opts)},
           {:parameters, compile_config!(:database_parameters)}
         ] ++
           if(compile_config(:database_password),
             do: [{:password, compile_config!(:database_password)}],
             else: []
           ) ++
           if(compile_config(:database_socket_dir),
             do: [{:socket_dir, compile_config!(:database_socket_dir)}],
             else: [{:hostname, compile_config!(:database_host)}]
           )

  config :domain, Domain.Tokens,
    key_base: compile_config!(:tokens_key_base),
    salt: compile_config!(:tokens_salt)

  config :domain, Domain.Gateways,
    gateway_ipv4_masquerade: compile_config!(:gateway_ipv4_masquerade),
    gateway_ipv6_masquerade: compile_config!(:gateway_ipv6_masquerade)

  config :domain, Domain.Auth.Adapters.GoogleWorkspace.APIClient,
    finch_transport_opts: compile_config!(:http_client_ssl_opts)

  config :domain, Domain.Billing.Stripe.APIClient,
    endpoint: "https://api.stripe.com",
    finch_transport_opts: []

  config :domain, Domain.Billing,
    enabled: compile_config!(:billing_enabled),
    secret_key: compile_config!(:stripe_secret_key),
    webhook_signing_secret: compile_config!(:stripe_webhook_signing_secret),
    default_price_id: compile_config!(:stripe_default_price_id)

  config :domain, platform_adapter: compile_config!(:platform_adapter)

  if platform_adapter = compile_config!(:platform_adapter) do
    config :domain, platform_adapter, compile_config!(:platform_adapter_config)
  end

  config :domain, Domain.Cluster,
    adapter: compile_config!(:erlang_cluster_adapter),
    adapter_config: compile_config!(:erlang_cluster_adapter_config)

  config :domain, Domain.Instrumentation,
    client_logs_enabled: compile_config!(:instrumentation_client_logs_enabled),
    client_logs_bucket: compile_config!(:instrumentation_client_logs_bucket)

  config :domain, Domain.Analytics,
    mixpanel_token: compile_config!(:mixpanel_token),
    hubspot_workspace_id: compile_config!(:hubspot_workspace_id)

  config :domain, :enabled_features,
    idp_sync: compile_config!(:feature_idp_sync_enabled),
    sign_up: compile_config!(:feature_sign_up_enabled),
    flow_activities: compile_config!(:feature_flow_activities_enabled),
    self_hosted_relays: compile_config!(:feature_self_hosted_relays_enabled),
    policy_conditions: compile_config!(:feature_policy_conditions_enabled),
    multi_site_resources: compile_config!(:feature_multi_site_resources_enabled),
    rest_api: compile_config!(:feature_rest_api_enabled),
    internet_resource: compile_config!(:feature_internet_resource_enabled)

  config :domain, sign_up_whitelisted_domains: compile_config!(:sign_up_whitelisted_domains)

  config :domain, docker_registry: compile_config!(:docker_registry)

  config :domain, outbound_email_adapter_configured?: !!compile_config!(:outbound_email_adapter)

  config :domain, web_external_url: compile_config!(:web_external_url)

  # Enable background jobs only on dedicated nodes
  config :domain, Domain.Tokens.Jobs.DeleteExpiredTokens,
    enabled: compile_config!(:background_jobs_enabled)

  config :domain, Domain.Billing.Jobs.CheckAccountLimits,
    enabled: compile_config!(:background_jobs_enabled)

  config :domain, Domain.Auth.Adapters.GoogleWorkspace.Jobs.RefreshAccessTokens,
    enabled: compile_config!(:background_jobs_enabled)

  config :domain, Domain.Auth.Adapters.GoogleWorkspace.Jobs.SyncDirectory,
    enabled: compile_config!(:background_jobs_enabled)

  config :domain, Domain.Auth.Adapters.MicrosoftEntra.Jobs.RefreshAccessTokens,
    enabled: compile_config!(:background_jobs_enabled)

  config :domain, Domain.Auth.Adapters.MicrosoftEntra.Jobs.SyncDirectory,
    enabled: compile_config!(:background_jobs_enabled)

  config :domain, Domain.Auth.Adapters.Okta.Jobs.RefreshAccessTokens,
    enabled: compile_config!(:background_jobs_enabled)

  config :domain, Domain.Auth.Adapters.Okta.Jobs.SyncDirectory,
    enabled: compile_config!(:background_jobs_enabled)

  if web_external_url = compile_config!(:web_external_url) do
    %{
      scheme: web_external_url_scheme,
      host: web_external_url_host,
      port: web_external_url_port,
      path: web_external_url_path
    } = URI.parse(web_external_url)

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
        scheme: web_external_url_scheme,
        host: web_external_url_host,
        port: web_external_url_port,
        path: web_external_url_path
      ],
      secret_key_base: compile_config!(:secret_key_base),
      check_origin: [
        "#{web_external_url_scheme}://#{web_external_url_host}:#{web_external_url_port}",
        "#{web_external_url_scheme}://*.#{web_external_url_host}:#{web_external_url_port}",
        "#{web_external_url_scheme}://#{web_external_url_host}",
        "#{web_external_url_scheme}://*.#{web_external_url_host}"
      ],
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

    config :web, api_url_override: compile_config!(:api_url_override)
  end

  if api_external_url = compile_config!(:api_external_url) do
    %{
      scheme: api_external_url_scheme,
      host: api_external_url_host,
      port: api_external_url_port,
      path: api_external_url_path
    } = URI.parse(api_external_url)

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
        scheme: api_external_url_scheme,
        host: api_external_url_host,
        port: api_external_url_port,
        path: api_external_url_path
      ],
      secret_key_base: compile_config!(:secret_key_base)

    config :api,
      cookie_secure: compile_config!(:phoenix_secure_cookies),
      cookie_signing_salt: compile_config!(:cookie_signing_salt),
      cookie_encryption_salt: compile_config!(:cookie_encryption_salt)

    config :api,
      external_trusted_proxies: compile_config!(:phoenix_external_trusted_proxies),
      private_clients: compile_config!(:phoenix_private_clients)

    config :web,
      api_external_url: api_external_url
  end

  ###############################
  ##### Third-party configs #####
  ###############################

  if logger_formatter = compile_config!(:logger_formatter) do
    logger_formatter_opts =
      compile_config!(:logger_formatter_opts) ++
        [metadata: {:all_except, [:socket, :conn, :otel_trace_flags]}]

    config :logger, :default_handler, formatter: {logger_formatter, logger_formatter_opts}
  end

  if System.get_env("OTLP_ENDPOINT") do
    config :opentelemetry, resource_detectors: [:otel_resource_env_var, :otel_resource_app_env]

    config :opentelemetry,
      span_processor: :batch,
      traces_exporter: :otlp

    config :opentelemetry_exporter,
      otlp_protocol: :http_protobuf,
      otlp_traces_protocol: :http_protobuf,
      otlp_endpoint: System.get_env("OTLP_ENDPOINT")
  end

  config :domain, Domain.Telemetry, metrics_reporter: compile_config!(:telemetry_metrics_reporter)

  if telemetry_metrics_reporter = compile_config!(:telemetry_metrics_reporter) do
    config :domain, telemetry_metrics_reporter, compile_config!(:telemetry_metrics_reporter_opts)
  end

  config :domain,
    http_client_ssl_opts: compile_config!(:http_client_ssl_opts)

  config :openid_connect,
    finch_transport_opts: compile_config!(:http_client_ssl_opts)

  config :domain,
         Domain.Mailer,
         [
           adapter: compile_config!(:outbound_email_adapter),
           from_email: compile_config!(:outbound_email_from)
         ] ++ compile_config!(:outbound_email_adapter_opts)

  config :workos, WorkOS.Client,
    api_key: compile_config!(:workos_api_key),
    client_id: compile_config!(:workos_client_id)

  # Sentry

  api_external_url_host = URI.parse(compile_config!(:api_external_url)).host

  sentry_environment_name =
    case api_external_url_host do
      "api.firezone.dev" -> :production
      "api.firez.one" -> :staging
      _ -> :unknown
    end

  sentry_dsn =
    case api_external_url_host do
      "api.firezone.dev" ->
        "https://29f4ab7c6c473c17bc01f8aeffb0ac16@o4507971108339712.ingest.us.sentry.io/4508756715569152"

      "api.firez.one" ->
        "https://29f4ab7c6c473c17bc01f8aeffb0ac16@o4507971108339712.ingest.us.sentry.io/4508756715569152"

      _ ->
        nil
    end

  config :sentry,
    dsn: sentry_dsn,
    environment_name: sentry_environment_name,
    enable_source_code_context: true,
    root_source_code_paths: [
      Path.join(File.cwd!(), "apps/domain"),
      Path.join(File.cwd!(), "apps/web"),
      Path.join(File.cwd!(), "apps/api")
    ]
end
