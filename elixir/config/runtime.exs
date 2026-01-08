import Config

if config_env() == :prod do
  import Portal.Config, only: [env_var_to_config!: 1, env_var_to_config: 1]

  ###############################
  ##### Portal ##################
  ###############################

  config :portal,
         Portal.Repo,
         [
           {:database, env_var_to_config!(:database_name)},
           {:username, env_var_to_config!(:database_user)},
           {:port, env_var_to_config!(:database_port)},
           {:pool_size, env_var_to_config!(:database_pool_size)},
           {:queue_target, env_var_to_config!(:database_queue_target)},
           {:queue_interval, env_var_to_config!(:database_queue_interval)},
           {:ssl, env_var_to_config!(:database_ssl_enabled)},
           {:ssl_opts, env_var_to_config!(:database_ssl_opts)},
           {:parameters, env_var_to_config!(:database_parameters)}
         ] ++
           if(env_var_to_config(:database_password),
             do: [{:password, env_var_to_config!(:database_password)}],
             else: []
           ) ++
           if(env_var_to_config(:database_socket_dir),
             do: [{:socket_dir, env_var_to_config!(:database_socket_dir)}],
             else: [{:hostname, env_var_to_config!(:database_host)}]
           )

  config :portal, Portal.ChangeLogs.ReplicationConnection,
    # TODO: Use a dedicated node for Change Log replication
    enabled: env_var_to_config!(:background_jobs_enabled),
    replication_slot_name: env_var_to_config!(:database_change_logs_replication_slot_name),
    publication_name: env_var_to_config!(:database_change_logs_publication_name),
    connection_opts:
      [
        port: env_var_to_config!(:database_port),
        ssl: env_var_to_config!(:database_ssl_enabled),
        ssl_opts: env_var_to_config!(:database_ssl_opts),
        parameters: env_var_to_config!(:database_parameters),
        username: env_var_to_config!(:database_user),
        database: env_var_to_config!(:database_name)
      ] ++
        if(env_var_to_config(:database_password),
          do: [{:password, env_var_to_config!(:database_password)}],
          else: []
        ) ++
        if(env_var_to_config(:database_socket_dir),
          do: [{:socket_dir, env_var_to_config!(:database_socket_dir)}],
          else: [{:hostname, env_var_to_config!(:database_host)}]
        )

  config :portal, Portal.Changes.ReplicationConnection,
    # TODO: Use a dedicated node for Change Data Capture replication
    enabled: env_var_to_config!(:background_jobs_enabled),
    replication_slot_name: env_var_to_config!(:database_changes_replication_slot_name),
    publication_name: env_var_to_config!(:database_changes_publication_name),
    connection_opts:
      [
        port: env_var_to_config!(:database_port),
        ssl: env_var_to_config!(:database_ssl_enabled),
        ssl_opts: env_var_to_config!(:database_ssl_opts),
        parameters: env_var_to_config!(:database_parameters),
        username: env_var_to_config!(:database_user),
        database: env_var_to_config!(:database_name)
      ] ++
        if(env_var_to_config(:database_password),
          do: [{:password, env_var_to_config!(:database_password)}],
          else: []
        ) ++
        if(env_var_to_config(:database_socket_dir),
          do: [{:socket_dir, env_var_to_config!(:database_socket_dir)}],
          else: [{:hostname, env_var_to_config!(:database_host)}]
        )

  config :portal, Portal.Tokens,
    key_base: env_var_to_config!(:tokens_key_base),
    salt: env_var_to_config!(:tokens_salt)

  config :portal, Portal.Google.APIClient,
    service_account_key: env_var_to_config!(:google_service_account_key),
    token_endpoint: "https://oauth2.googleapis.com/token",
    endpoint: "https://www.googleapis.com"

  config :portal, Portal.Google.AuthProvider,
    client_id: env_var_to_config!(:google_oidc_client_id),
    client_secret: env_var_to_config!(:google_oidc_client_secret)

  config :portal, Portal.Entra.AuthProvider,
    client_id: env_var_to_config!(:entra_oidc_client_id),
    client_secret: env_var_to_config!(:entra_oidc_client_secret)

  config :portal, Portal.Entra.APIClient,
    client_id: env_var_to_config!(:entra_sync_client_id),
    client_secret: env_var_to_config!(:entra_sync_client_secret),
    token_base_url: "https://login.microsoftonline.com",
    endpoint: "https://graph.microsoft.com"

  config :portal, Portal.Billing.Stripe.APIClient, endpoint: "https://api.stripe.com"

  config :portal, Portal.Billing,
    enabled: env_var_to_config!(:billing_enabled),
    secret_key: env_var_to_config!(:stripe_secret_key),
    webhook_signing_secret: env_var_to_config!(:stripe_webhook_signing_secret),
    default_price_id: env_var_to_config!(:stripe_default_price_id)

  config :portal, platform_adapter: env_var_to_config!(:platform_adapter)

  if platform_adapter = env_var_to_config!(:platform_adapter) do
    config :portal, platform_adapter, env_var_to_config!(:platform_adapter_config)
  end

  config :portal, Portal.Cluster,
    adapter: env_var_to_config!(:erlang_cluster_adapter),
    adapter_config: env_var_to_config!(:erlang_cluster_adapter_config),
    secondary_adapter: env_var_to_config!(:erlang_cluster_adapter_secondary),
    secondary_adapter_config: env_var_to_config!(:erlang_cluster_adapter_secondary_config)

  config :portal, :enabled_features,
    idp_sync: env_var_to_config!(:feature_idp_sync_enabled),
    sign_up: env_var_to_config!(:feature_sign_up_enabled),
    policy_conditions: env_var_to_config!(:feature_policy_conditions_enabled),
    multi_site_resources: env_var_to_config!(:feature_multi_site_resources_enabled),
    rest_api: env_var_to_config!(:feature_rest_api_enabled),
    internet_resource: env_var_to_config!(:feature_internet_resource_enabled)

  config :portal, sign_up_whitelisted_domains: env_var_to_config!(:sign_up_whitelisted_domains)

  config :portal, docker_registry: env_var_to_config!(:docker_registry)

  config :portal,
    outbound_email_adapter_configured?: !!env_var_to_config!(:outbound_email_adapter)

  config :portal, web_external_url: env_var_to_config!(:web_external_url)

  # Shared cookie and proxy config (used by both Web and API endpoints)
  config :portal,
    cookie_secure: env_var_to_config!(:phoenix_secure_cookies),
    cookie_signing_salt: env_var_to_config!(:cookie_signing_salt),
    cookie_encryption_salt: env_var_to_config!(:cookie_encryption_salt)

  config :portal,
    external_trusted_proxies: env_var_to_config!(:phoenix_external_trusted_proxies),
    private_clients: env_var_to_config!(:phoenix_private_clients)

  # Oban has its own config validation that prevents overriding config in runtime.exs,
  # so we explicitly set the config in dev.exs, test.exs, and runtime.exs (for prod) only.
  config :portal, Oban,
    # Periodic jobs don't make sense in tests
    plugins: [
      # Keep the last 7 days of completed, cancelled, and discarded jobs
      {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},

      # Rescue jobs that have been stuck in executing state due to node crashes,
      # deploys, or other issues. Jobs will be moved back to available state
      # after the timeout. This can happen after a deploy or if a node crashes.
      {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(120)},

      # Periodic jobs
      {Oban.Plugins.Cron,
       crontab: [
         # Delete expired policy_authorizations every minute
         {"* * * * *", Portal.Workers.DeleteExpiredPolicyAuthorizations},

         # Schedule Entra directory sync every 2 hours
         {"0 */2 * * *", Portal.Entra.Scheduler},

         # Schedule Google directory sync every 2 hours
         {"20 */2 * * *", Portal.Google.Scheduler},

         # Schedule Okta directory sync every 2 hours
         {"40 */2 * * *", Portal.Okta.Scheduler},

         # Directory sync error notifications - daily check for low error count
         {"0 9 * * *", Portal.Workers.SyncErrorNotification,
          args: %{provider: "entra", frequency: "daily"}},
         {"0 9 * * *", Portal.Workers.SyncErrorNotification,
          args: %{provider: "google", frequency: "daily"}},
         {"0 9 * * *", Portal.Workers.SyncErrorNotification,
          args: %{provider: "okta", frequency: "daily"}},

         # Directory sync error notifications - every 3 days for medium error count
         {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
          args: %{provider: "entra", frequency: "three_days"}},
         {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
          args: %{provider: "google", frequency: "three_days"}},
         {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
          args: %{provider: "okta", frequency: "three_days"}},

         # Directory sync error notifications - weekly for high error count
         {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
          args: %{provider: "entra", frequency: "weekly"}},
         {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
          args: %{provider: "google", frequency: "weekly"}},
         {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
          args: %{provider: "okta", frequency: "weekly"}},

         # Check account limits every 30 minutes
         {"*/30 * * * *", Portal.Workers.CheckAccountLimits},

         # Check for outdated gateways - Sundays at 9am
         {"0 9 * * 0", Portal.Workers.OutdatedGateways},

         # Delete expired tokens every 5 minutes
         {"*/5 * * * *", Portal.Workers.DeleteExpiredClientTokens},

         # Delete expired API tokens every 5 minutes
         {"*/5 * * * *", Portal.Workers.DeleteExpiredAPITokens},

         # Delete expired one-time passcodes every 5 minutes
         {"*/5 * * * *", Portal.Workers.DeleteExpiredOneTimePasscodes},

         # Delete expired portal sessions every 5 minutes
         {"*/5 * * * *", Portal.Workers.DeleteExpiredPortalSessions}
       ]}
    ],
    queues:
      if(env_var_to_config!(:background_jobs_enabled),
        do: [
          default: 10,
          entra_scheduler: 1,
          entra_sync: 5,
          google_scheduler: 1,
          google_sync: 5,
          okta_scheduler: 1,
          okta_sync: 5,
          sync_error_notifications: 1
        ],
        else: []
      ),
    engine: Oban.Engines.Basic,
    repo: Portal.Repo

  ###############################
  ##### PortalWeb Endpoint ######
  ###############################

  if web_external_url = env_var_to_config!(:web_external_url) do
    %{
      scheme: web_external_url_scheme,
      host: web_external_url_host,
      port: web_external_url_port,
      path: web_external_url_path
    } = URI.parse(web_external_url)

    config :portal, PortalWeb.Endpoint,
      http: [
        ip: env_var_to_config!(:phoenix_listen_address).address,
        port: env_var_to_config!(:phoenix_http_web_port),
        http_1_options: env_var_to_config!(:phoenix_http_protocol_options)
      ],
      url: [
        scheme: web_external_url_scheme,
        host: web_external_url_host,
        port: web_external_url_port,
        path: web_external_url_path
      ],
      secret_key_base: env_var_to_config!(:secret_key_base),
      check_origin: [
        "#{web_external_url_scheme}://#{web_external_url_host}:#{web_external_url_port}",
        "#{web_external_url_scheme}://*.#{web_external_url_host}:#{web_external_url_port}",
        "#{web_external_url_scheme}://#{web_external_url_host}",
        "#{web_external_url_scheme}://*.#{web_external_url_host}"
      ],
      live_view: [
        signing_salt: env_var_to_config!(:live_view_signing_salt)
      ]

    config :portal, api_url_override: env_var_to_config!(:api_url_override)
  end

  ###############################
  ##### PortalAPI Endpoint ######
  ###############################

  if api_external_url = env_var_to_config!(:api_external_url) do
    %{
      scheme: api_external_url_scheme,
      host: api_external_url_host,
      port: api_external_url_port,
      path: api_external_url_path
    } = URI.parse(api_external_url)

    config :portal, PortalAPI.Endpoint,
      http: [
        ip: env_var_to_config!(:phoenix_listen_address).address,
        port: env_var_to_config!(:phoenix_http_api_port),
        http_1_options: env_var_to_config!(:phoenix_http_protocol_options)
      ],
      url: [
        scheme: api_external_url_scheme,
        host: api_external_url_host,
        port: api_external_url_port,
        path: api_external_url_path
      ],
      secret_key_base: env_var_to_config!(:secret_key_base)

    config :portal, PortalAPI.RateLimit,
      refill_rate: env_var_to_config!(:api_refill_rate),
      capacity: env_var_to_config!(:api_capacity)

    config :portal,
      api_external_url: api_external_url
  end

  ###############################
  ##### Third-party configs #####
  ###############################

  if System.get_env("OTLP_ENDPOINT") do
    config :opentelemetry,
      resource_detectors: [:otel_resource_env_var, :otel_resource_app_env],
      resource: %{
        service: %{
          # These are populated on our GCP VMs
          name: System.get_env("APPLICATION_NAME"),
          namespace: System.get_env("GCP_PROJECT_ID"),
          version: System.get_env("RELEASE_VSN"),
          instance: %{id: System.get_env("GCP_INSTANCE_NAME")}
        }
      }

    config :opentelemetry,
      span_processor: :batch,
      traces_exporter: :otlp

    config :opentelemetry_exporter,
      otlp_protocol: :http_protobuf,
      otlp_traces_protocol: :http_protobuf,
      otlp_endpoint: System.get_env("OTLP_ENDPOINT")
  end

  config :portal, Portal.Health, health_port: env_var_to_config!(:health_port)

  config :portal, Portal.Telemetry,
    metrics_reporter: env_var_to_config!(:telemetry_metrics_reporter)

  if telemetry_metrics_reporter = env_var_to_config!(:telemetry_metrics_reporter) do
    config :portal,
           telemetry_metrics_reporter,
           env_var_to_config!(:telemetry_metrics_reporter_opts)
  end

  config :portal,
    http_client_ssl_opts: env_var_to_config!(:http_client_ssl_opts)

  config :openid_connect,
    finch_transport_opts: env_var_to_config!(:http_client_ssl_opts)

  config :portal,
         Portal.Mailer,
         [
           adapter: env_var_to_config!(:outbound_email_adapter),
           from_email: env_var_to_config!(:outbound_email_from)
         ] ++ env_var_to_config!(:outbound_email_adapter_opts)

  # Sentry

  with api_external_url when not is_nil(api_external_url) <-
         env_var_to_config!(:api_external_url),
       api_external_url_host <- URI.parse(api_external_url).host,
       environment_name when environment_name in [:staging, :production] <-
         (case api_external_url_host do
            "api.firezone.dev" -> :production
            "api.firez.one" -> :staging
            _ -> :unknown
          end) do
    config :sentry,
      environment_name: environment_name,
      dsn:
        "https://29f4ab7c6c473c17bc01f8aeffb0ac16@o4507971108339712.ingest.us.sentry.io/4508756715569152"
  end
end
