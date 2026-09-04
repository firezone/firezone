import Config

if config_env() == :prod do
  import Portal.Config, only: [env_var_to_config!: 1, env_var_to_config: 1]

  ###############################
  ##### Portal ##################
  ###############################

  config :portal, Portal.Azure.ManagedIdentity,
    client_id: env_var_to_config!(:azure_client_id)

  if env_var_to_config!(:database_entra_auth) && !env_var_to_config(:azure_client_id) do
    raise "AZURE_CLIENT_ID must be set when DATABASE_ENTRA_AUTH is enabled"
  end

  # With Entra auth the "password" is a short-lived Entra access token for the
  # VM's managed identity, fetched before every connect attempt.
  database_password_opts =
    cond do
      env_var_to_config!(:database_entra_auth) ->
        [{:configure, {Portal.Azure.ManagedIdentity, :put_database_token, []}}]

      env_var_to_config(:database_password) ->
        [{:password, env_var_to_config!(:database_password)}]

      true ->
        []
    end

  config :portal,
         Portal.Repo,
         [
           {:database, env_var_to_config!(:database_name)},
           {:username, env_var_to_config!(:database_user)},
           {:port, env_var_to_config!(:database_port)},
           {:pool_size, env_var_to_config!(:database_pool_size)},
           {:queue_target, env_var_to_config!(:database_queue_target)},
           {:queue_interval, env_var_to_config!(:database_queue_interval)},
           {:ssl, env_var_to_config!(:database_ssl)},
           {:parameters, env_var_to_config!(:database_parameters)}
         ] ++
           if(env_var_to_config!(:database_socket_options) != [],
             do: [{:socket_options, env_var_to_config!(:database_socket_options)}],
             else: []
           ) ++
           database_password_opts ++
           if(env_var_to_config(:database_socket_dir),
             do: [{:socket_dir, env_var_to_config!(:database_socket_dir)}],
             else: [{:hostname, env_var_to_config!(:database_host)}]
           )

  # Shared connection options for the isolated pools
  pool_base_opts =
    [
      {:database, env_var_to_config!(:database_name)},
      {:username, env_var_to_config!(:database_user)},
      {:queue_target, env_var_to_config!(:database_queue_target)},
      {:queue_interval, env_var_to_config!(:database_queue_interval)},
      {:ssl, env_var_to_config!(:database_ssl)}
    ] ++
      if(env_var_to_config!(:database_socket_options) != [],
        do: [{:socket_options, env_var_to_config!(:database_socket_options)}],
        else: []
      ) ++
      database_password_opts ++
      if(env_var_to_config(:database_socket_dir),
        do: [{:socket_dir, env_var_to_config!(:database_socket_dir)}],
        else: [{:hostname, env_var_to_config!(:database_host)}]
      )

  direct_pool_base_opts =
    [{:port, env_var_to_config!(:database_port)}] ++ pool_base_opts

  pgbouncer_pool_base_opts =
    case env_var_to_config(:database_pgbouncer_port) do
      nil ->
        direct_pool_base_opts

      port ->
        [{:port, port}, {:prepare, :unnamed}] ++ pool_base_opts
    end

  database_parameters = env_var_to_config!(:database_parameters)

  # Transaction-pooled connection pools. When DATABASE_PGBOUNCER_PORT is not
  # set they fall back to the direct PostgreSQL endpoint for compatibility.
  for {repo, pool_size_key, app_name} <- [
        {Portal.Repo.Web, :database_pool_size_web, "web"},
        {Portal.Repo.Api, :database_pool_size_api, "api"},
        {Portal.Repo.Job, :database_pool_size_job, "job"}
      ] do
    config :portal,
           repo,
           [
             {:pool_size, env_var_to_config!(pool_size_key)},
             {:parameters, Keyword.merge(database_parameters, application_name: app_name)}
           ] ++ pgbouncer_pool_base_opts
  end

  # Isolated poller connection pool, sized for the two slot pollers: poll
  # cycles hold a connection for as long as a cycle runs, which must not
  # starve the shared pools
  config :portal,
         Portal.Repo.Poller,
         [
           {:pool_size, 2},
           {:parameters, Keyword.merge(database_parameters, application_name: "poller")}
         ] ++ direct_pool_base_opts

  config :portal, Portal.ChangeLogs.Consumer,
    enabled: env_var_to_config!(:change_logs_replication_enabled),
    replication_slot_name: env_var_to_config!(:database_change_logs_replication_slot_name),
    publication_name: env_var_to_config!(:database_change_logs_publication_name)

  config :portal, Portal.Changes.Consumer,
    enabled: env_var_to_config!(:changes_replication_enabled),
    region: env_var_to_config!(:region),
    replication_slot_name: env_var_to_config!(:database_changes_replication_slot_name),
    publication_name: env_var_to_config!(:database_changes_publication_name)

  config :portal, Portal.Tokens,
    key_base: env_var_to_config!(:tokens_key_base),
    salt: env_var_to_config!(:tokens_salt)

  config :portal, Portal.Google.APIClient,
    service_account_key: env_var_to_config!(:google_service_account_key),
    service_account_email: env_var_to_config!(:google_service_account_email),
    workload_identity_provider: env_var_to_config!(:google_workload_identity_provider),
    workload_identity_audience: env_var_to_config!(:google_workload_identity_audience),
    endpoint: "https://www.googleapis.com"

  config :portal, Portal.Google.AuthProvider,
    client_id: env_var_to_config!(:google_oidc_client_id),
    client_secret: env_var_to_config!(:google_oidc_client_secret)

  config :portal, Portal.Google.SyncAuthorization,
    client_id: env_var_to_config!(:google_sync_authz_client_id),
    client_secret: env_var_to_config!(:google_sync_authz_client_secret)

  # When ENTRA_OIDC_CLIENT_SECRET is unset, authorization-code redemption
  # authenticates with a token-exchange assertion from the portal's managed
  # identity. The optional secret supports dev and migration environments.
  # The Entra app registration must set groupMembershipClaims to DirectoryRole
  # so setup tokens include the signed `wids` claim used for the admin check.
  config :portal, Portal.Entra.AuthProvider,
    client_id: env_var_to_config!(:entra_oidc_client_id),
    client_secret: env_var_to_config!(:entra_oidc_client_secret)

  # Entra directory sync and Intune device inventory use separate Microsoft Graph
  # app registrations. Production authenticates both through workload identity
  # federation using the portal's managed identity, minting a token-exchange
  # assertion (Portal.Azure.ManagedIdentity). The optional secrets still flow
  # from config.exs for environments that set them.
  #
  # Both app registrations must also declare the delegated Microsoft Graph
  # permissions `openid` and `profile`, and set groupMembershipClaims to
  # DirectoryRole, so the `.default` admin-consent grant covers the signed user
  # identity proof without a second consent prompt.
  config :portal, Portal.Microsoft.Graph.APIClient,
    token_base_url: "https://login.microsoftonline.com",
    endpoint: "https://graph.microsoft.com",
    applications: [
      entra: [client_id: env_var_to_config!(:entra_sync_client_id), client_secret: nil],
      intune: [client_id: env_var_to_config!(:intune_sync_client_id), client_secret: nil]
    ]

  # Defender for Endpoint uses its own app registration, granted Machine.Read.All
  # on the WindowsDefenderATP API rather than on Microsoft Graph. It follows the
  # same rules as the two above: no client secret in production, and the
  # delegated Graph `openid` and `profile` permissions plus groupMembershipClaims
  # set to DirectoryRole so one admin-consent grant also covers the signed user
  # identity proof.
  config :portal, Portal.Defender.APIClient,
    client_id: env_var_to_config!(:defender_sync_client_id),
    client_secret: nil,
    token_base_url: "https://login.microsoftonline.com",
    endpoint: "https://api.security.microsoft.com",
    token_scope: "https://api.securitycenter.microsoft.com/.default"

  # No client secret: production authenticates the app with workload identity
  # federation, minting a token-exchange assertion from the portal's managed
  # identity (Portal.Azure.ManagedIdentity).
  config :portal, Portal.Sentinel.APIClient,
    client_id: env_var_to_config!(:sentinel_sync_client_id),
    token_base_url: "https://login.microsoftonline.com",
    discovery_document_uri:
      "https://login.microsoftonline.com/organizations/v2.0/.well-known/openid-configuration"

  config :portal, Portal.Billing.Stripe.APIClient, endpoint: "https://api.stripe.com"

  config :portal,
         Portal.Billing,
         [
           enabled: env_var_to_config!(:billing_enabled),
           secret_key: env_var_to_config!(:stripe_secret_key),
           webhook_signing_secret: env_var_to_config!(:stripe_webhook_signing_secret),
           default_price_id: env_var_to_config!(:stripe_default_price_id)
         ] ++
           if(env_var_to_config(:stripe_plan_product_ids) != [],
             do: [plan_product_ids: env_var_to_config!(:stripe_plan_product_ids)],
             else: []
           ) ++
           if(env_var_to_config(:stripe_adhoc_device_product_id),
             do: [adhoc_device_product_id: env_var_to_config!(:stripe_adhoc_device_product_id)],
             else: []
           )

  config :portal, region: env_var_to_config!(:region)

  config :portal, Portal.Cluster,
    adapter: env_var_to_config!(:erlang_cluster_adapter),
    adapter_config: env_var_to_config!(:erlang_cluster_adapter_config),
    secondary_adapter: env_var_to_config!(:erlang_cluster_adapter_secondary),
    secondary_adapter_config: env_var_to_config!(:erlang_cluster_adapter_secondary_config)

  config :portal, sign_up_whitelisted_domains: env_var_to_config!(:sign_up_whitelisted_domains)
  config :portal, country_code_blocklist: env_var_to_config!(:country_code_blocklist)

  config :portal,
    outbound_email_adapter_configured?: !!env_var_to_config!(:outbound_email_adapter)

  config :portal, web_external_url: env_var_to_config!(:web_external_url)

  # Shared cookie and proxy config (used by both Web and API endpoints)
  config :portal,
    cookie_secure: env_var_to_config!(:phoenix_secure_cookies),
    cookie_signing_salt: env_var_to_config!(:cookie_signing_salt),
    cookie_encryption_salt: env_var_to_config!(:cookie_encryption_salt),
    ops_cookie_signing_salt: env_var_to_config!(:ops_cookie_signing_salt),
    ops_admin_username: env_var_to_config!(:ops_admin_username),
    ops_admin_password: env_var_to_config!(:ops_admin_password)

  config :portal,
    external_trusted_proxies: env_var_to_config!(:phoenix_external_trusted_proxies),
    private_clients: env_var_to_config!(:phoenix_private_clients)

  config :portal,
    flow_logs_api_url: env_var_to_config!(:flow_logs_api_url),
    flow_logs_upload_interval_secs: env_var_to_config!(:flow_logs_upload_interval_secs)

  config :portal, Portal.S3.APIClient,
    access_key_id: env_var_to_config!(:log_sinks_aws_access_key_id),
    secret_access_key: env_var_to_config!(:log_sinks_aws_secret_access_key),
    aws_account_id: env_var_to_config!(:log_sinks_aws_account_id)

  # Oban has its own config validation that prevents overriding config in runtime.exs,
  # so we explicitly set the config in dev.exs, test.exs, and runtime.exs (for prod) only.
  oban_crontab = [
    # Delete expired policy_authorizations every minute
    {"* * * * *", Portal.Workers.DeleteExpiredPolicyAuthorizations},

    # Refresh cached certificate revocation lists hourly
    {"15 */2 * * *", Portal.Crl.Scheduler},

    # Refresh cached OCSP statuses hourly, for CAs that publish no list
    {"45 3 * * *", Portal.Ocsp.Scheduler},

    # Schedule Entra directory sync daily; Graph change notifications cover
    # the hours in between
    {"0 3 * * *", Portal.Entra.Scheduler},

    # Schedule Intune device inventory sync every 2 hours
    {"10 */2 * * *", Portal.Intune.Scheduler},

    # Schedule Iru device inventory sync every 2 hours
    {"50 */2 * * *", Portal.Iru.Scheduler},

    # Schedule Defender device inventory sync every 2 hours
    {"30 */2 * * *", Portal.Defender.Scheduler},

    # Schedule Santa device inventory sync every 2 hours
    {"40 */2 * * *", Portal.Santa.Scheduler},

    # Schedule SentinelOne device inventory sync every 2 hours
    {"35 */2 * * *", Portal.SentinelOne.Scheduler},

    # Group membership changes do not produce user push notifications, so run
    # a full Google directory sync every four hours.
    {"20 */4 * * *", Portal.Google.Scheduler},

    # Schedule Okta directory sync every 2 hours
    {"40 */2 * * *", Portal.Okta.Scheduler},

    # Schedule log sink deliveries every minute
    {"* * * * *", Portal.Splunk.Scheduler},
    {"* * * * *", Portal.Datadog.Scheduler},
    {"* * * * *", Portal.NewRelic.Scheduler},
    {"* * * * *", Portal.Elastic.Scheduler},
    {"* * * * *", Portal.Sentinel.Scheduler},
    {"* * * * *", Portal.S3.Scheduler},
    {"* * * * *", Portal.QRadar.Scheduler},
    {"* * * * *", Portal.HTTP.Scheduler},

    # Directory sync error notifications - daily check for low error count
    {"0 9 * * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "entra", frequency: "daily"}},
    {"0 9 * * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "google", frequency: "daily"}},
    {"0 9 * * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "okta", frequency: "daily"}},
    {"0 9 * * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "intune", frequency: "daily"}},
    {"0 9 * * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "iru", frequency: "daily"}},
    {"0 9 * * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "defender", frequency: "daily"}},
    {"0 9 * * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "santa", frequency: "daily"}},
    {"0 9 * * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "sentinelone", frequency: "daily"}},

    # Directory sync error notifications - every 3 days for medium error count
    {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "entra", frequency: "three_days"}},
    {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "google", frequency: "three_days"}},
    {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "okta", frequency: "three_days"}},
    {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "intune", frequency: "three_days"}},
    {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "iru", frequency: "three_days"}},
    {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "defender", frequency: "three_days"}},
    {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "santa", frequency: "three_days"}},
    {"0 9 */3 * *", Portal.Workers.SyncErrorNotification,
     args: %{provider: "sentinelone", frequency: "three_days"}},

    # Directory sync error notifications - weekly for high error count
    {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
     args: %{provider: "entra", frequency: "weekly"}},
    {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
     args: %{provider: "google", frequency: "weekly"}},
    {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
     args: %{provider: "okta", frequency: "weekly"}},
    {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
     args: %{provider: "intune", frequency: "weekly"}},
    {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
     args: %{provider: "iru", frequency: "weekly"}},
    {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
     args: %{provider: "defender", frequency: "weekly"}},
    {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
     args: %{provider: "santa", frequency: "weekly"}},
    {"0 9 * * 1", Portal.Workers.SyncErrorNotification,
     args: %{provider: "sentinelone", frequency: "weekly"}},

    # Log sink delivery error notifications
    {"0 9 * * *", Portal.Workers.LogSinkErrorNotification},

    # Check account limits every 30 minutes
    {"*/30 * * * *", Portal.Workers.CheckAccountLimits},

    # Check for outdated gateways - Sundays at 9am
    {"0 9 * * 0", Portal.Workers.OutdatedGateways},

    # Delete expired tokens every 5 minutes
    {"*/5 * * * *", Portal.Workers.DeleteExpiredClientTokens},

    # Delete expired API tokens every 5 minutes
    {"*/5 * * * *", Portal.Workers.DeleteExpiredAPITokens},

    # Delete rotated gateway tokens past their grace period every 5 minutes
    {"*/5 * * * *", Portal.Workers.DeleteRotatedGatewayTokens},

    # Delete expired one-time passcodes every 5 minutes
    {"*/5 * * * *", Portal.Workers.DeleteExpiredOneTimePasscodes},

    # Delete expired portal sessions every 5 minutes
    {"*/5 * * * *", Portal.Workers.DeleteExpiredPortalSessions},

    # Delete old change_logs every 5 minutes
    {"*/5 * * * *", Portal.Workers.DeleteOldChangeLogs},

    # Maintain flow_logs partitions (pre-create upcoming, drop expired) daily
    {"30 3 * * *", Portal.Workers.PartitionFlowLogs},

    # Delete old session_logs every 5 minutes
    {"*/5 * * * *", Portal.Workers.DeleteOldSessionLogs},

    # Delete old api_request_logs every 5 minutes
    {"*/5 * * * *", Portal.Workers.DeleteOldAPIRequestLogs},

    # Sweep accounts due for deletion every minute
    {"* * * * *", Portal.Workers.SweepAccountDeletions}
  ]

  config :portal, Oban,
    notifier: Oban.Notifiers.PG,
    peer: Oban.Peers.Database,
    plugins: [
      {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
      {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(120)},
      {Oban.Plugins.Cron, crontab: oban_crontab}
    ],
    queues: [
      default: 10,
      crl_scheduler: 1,
      crl_sync: 5,
      ocsp_scheduler: 1,
      ocsp_sync: 5,
      entra_scheduler: 1,
      entra_sync: 5,
    entra_subscriptions: 1,
    entra_webhook: 5,
      intune_scheduler: 1,
      intune_sync: 5,
      iru_scheduler: 1,
      iru_sync: 5,
      defender_scheduler: 1,
      defender_sync: 5,
      santa_scheduler: 1,
      santa_sync: 5,
      sentinelone_scheduler: 1,
      sentinelone_sync: 5,
      google_scheduler: 1,
      google_sync: 5,
      google_subscriptions: 1,
      google_webhook: 5,
      okta_scheduler: 1,
      okta_sync: 5,
      splunk_scheduler: 1,
      splunk_sync: 5,
      datadog_scheduler: 1,
      datadog_sync: 5,
      newrelic_scheduler: 1,
      newrelic_sync: 5,
      elastic_scheduler: 1,
      elastic_sync: 5,
      sentinel_scheduler: 1,
      sentinel_sync: 5,
      s3_scheduler: 1,
      s3_sync: 5,
      qradar_scheduler: 1,
      qradar_sync: 5,
      http_scheduler: 1,
      http_sync: 5,
      sync_error_notifications: 1,
      outbound_emails: 1
    ],
    engine: Oban.Engines.Basic,
    repo: Portal.Repo.Job

  ###############################
  ##### Public Endpoint #########
  ###############################

  public_http =
    case env_var_to_config(:phoenix_http_public_port) do
      nil ->
        []

      port ->
        [
          http: [
            ip: env_var_to_config!(:phoenix_listen_address).address,
            port: port,
            http_1_options: env_var_to_config!(:phoenix_http_protocol_options)
          ]
        ]
    end

  public_https =
    case env_var_to_config(:phoenix_https_public_port) do
      nil ->
        []

      port ->
        sni_hosts = env_var_to_config!(:phoenix_https_sni_hosts)

        if sni_hosts == %{} do
          raise "PHOENIX_HTTPS_SNI_HOSTS must be set when PHOENIX_HTTPS_PUBLIC_PORT is set"
        end

        [
          https: [
            ip: env_var_to_config!(:phoenix_listen_address).address,
            port: port,
            http_1_options: env_var_to_config!(:phoenix_http_protocol_options),
            thousand_island_options: [
              transport_options: [
                sni_fun:
                  Portal.TLS.sni_fun(
                    sni_hosts,
                    env_var_to_config(:mtls_external_url)
                  )
              ]
            ]
          ]
        ]
    end

  web_external_url = env_var_to_config!(:web_external_url)
  web_external_url_host = URI.parse(web_external_url).host

  config :portal,
         Portal.Endpoint,
         public_http ++ public_https ++
           [
             url: [scheme: "https", host: web_external_url_host, port: 443],
             secret_key_base: env_var_to_config!(:secret_key_base)
           ]

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

    # Plain HTTP URLs are used by the local Docker Compose environment. HTTPS
    # deployments are served exclusively through Portal.Endpoint, which owns
    # TLS and dispatches requests by hostname.
    web_listener =
      if web_external_url_scheme == "http" do
        [
          http: [
            ip: env_var_to_config!(:phoenix_listen_address).address,
            port: web_external_url_port,
            http_1_options: env_var_to_config!(:phoenix_http_protocol_options)
          ]
        ]
      else
        []
      end

    config :portal,
           PortalWeb.Endpoint,
           web_listener ++
             [
               server: web_external_url_scheme == "http",
               url: [
                 scheme: web_external_url_scheme,
                 host: web_external_url_host,
                 port: web_external_url_port,
                 path: web_external_url_path
               ],
               secret_key_base: env_var_to_config!(:secret_key_base),
               check_origin:
                 [
                   "#{web_external_url_scheme}://#{web_external_url_host}:#{web_external_url_port}",
                   "#{web_external_url_scheme}://*.#{web_external_url_host}:#{web_external_url_port}",
                   "#{web_external_url_scheme}://#{web_external_url_host}",
                   "#{web_external_url_scheme}://*.#{web_external_url_host}"
                 ] ++ env_var_to_config!(:websocket_additional_origins),
               live_view: [
                 signing_salt: env_var_to_config!(:live_view_signing_salt)
               ]
             ]

    config :portal, PortalWeb.RateLimit,
      refill_rate: env_var_to_config!(:web_refill_rate),
      capacity: env_var_to_config!(:web_capacity)

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

    api_listener =
      if api_external_url_scheme == "http" do
        [
          http: [
            ip: env_var_to_config!(:phoenix_listen_address).address,
            port: api_external_url_port,
            http_1_options: env_var_to_config!(:phoenix_http_protocol_options)
          ]
        ]
      else
        []
      end

    config :portal,
           PortalAPI.Endpoint,
           api_listener ++
             [
               server: api_external_url_scheme == "http",
               url: [
                 scheme: api_external_url_scheme,
                 host: api_external_url_host,
                 port: api_external_url_port,
                 path: api_external_url_path
               ],
               secret_key_base: env_var_to_config!(:secret_key_base)
             ]

    config :portal, PortalAPI.RateLimit,
      refill_rate: env_var_to_config!(:api_refill_rate),
      capacity: env_var_to_config!(:api_capacity)

    config :portal, PortalAPI.Sockets.RateLimit,
      refill_rate: env_var_to_config!(:api_socket_refill_rate),
      capacity: env_var_to_config!(:api_socket_capacity)

    config :portal, PortalAPI.Plugs.IngestionRateLimit,
      refill_rate: env_var_to_config!(:api_ingestion_refill_rate),
      capacity: env_var_to_config!(:api_ingestion_capacity)

    config :portal,
      api_external_url: api_external_url,
      rest_api_url: env_var_to_config!(:rest_api_url) || api_external_url,
      mtls_external_url: env_var_to_config!(:mtls_external_url)
  end

  ###############################
  ##### PortalOps Endpoint ######
  ###############################

  config :portal, PortalOps.Endpoint,
    http: [
      ip: env_var_to_config!(:phoenix_listen_address).address,
      port: env_var_to_config!(:phoenix_http_ops_port),
      http_1_options: env_var_to_config!(:phoenix_http_protocol_options)
    ],
    url: [
      scheme: "http",
      host: "localhost",
      port: env_var_to_config!(:phoenix_http_ops_port),
      path: nil
    ],
    secret_key_base: env_var_to_config!(:ops_secret_key_base),
    live_view: [
      signing_salt: env_var_to_config!(:ops_live_view_signing_salt)
    ],
    check_origin: [
      "//#{env_var_to_config!(:ops_websocket_origin)}:#{env_var_to_config!(:ops_websocket_port)}"
    ]

  ###############################
  ##### Third-party configs #####
  ###############################

  if maxmind_city_db_path = env_var_to_config!(:maxmind_city_db_path) do
    config :geolix,
      databases: [
        %{
          id: :city,
          adapter: Geolix.Adapter.MMDB2,
          source: maxmind_city_db_path
        }
      ]
  end

  if System.get_env("OTLP_ENDPOINT") do
    config :opentelemetry,
      resource_detectors: [:otel_resource_env_var, :otel_resource_app_env],
      resource: %{
        service: %{
          name: "portal",
          namespace: "firezone",
          version: System.get_env("RELEASE_VSN"),
          instance: %{id: System.get_env("NODE_NAME")}
        },
        host: %{
          name: System.get_env("NODE_NAME"),
          id: System.get_env("NODE_NAME")
        },
        cloud: %{
          provider: "azure",
          region: System.get_env("REGION")
        }
      }

    config :opentelemetry,
      span_processor: :batch,
      traces_exporter: :otlp

    config :opentelemetry_exporter,
      otlp_protocol: :http_protobuf,
      otlp_traces_protocol: :http_protobuf,
      otlp_endpoint: System.get_env("OTLP_ENDPOINT")

    config :opentelemetry_experimental,
      readers: [
        %{
          module: :otel_metric_reader,
          config: %{
            export_interval_ms: 30_000,
            exporter:
              {:otel_exporter_metrics_otlp, %{endpoints: [System.get_env("OTLP_ENDPOINT")]}}
          }
        }
      ]
  end

  config :portal, Portal.Telemetry,
    metrics_reporter: env_var_to_config!(:telemetry_metrics_reporter)

  posthog_project_api_key = env_var_to_config(:posthog_project_api_key)

  config :portal, Portal.Analytics.PostHog,
    enabled: not is_nil(posthog_project_api_key),
    project_api_key: posthog_project_api_key

  if telemetry_metrics_reporter = env_var_to_config!(:telemetry_metrics_reporter) do
    config :portal,
           telemetry_metrics_reporter,
           env_var_to_config!(:telemetry_metrics_reporter_opts)
  end

  config :portal,
    http_client_ssl_opts: env_var_to_config!(:http_client_ssl_opts)

  if !env_var_to_config!(:http_client_ssrf_protection_enabled) do
    config :req, default_options: [plugins: []]
  end

  config :portal,
         Portal.Mailer,
         [
           adapter: env_var_to_config!(:outbound_email_adapter),
           from_email: env_var_to_config!(:outbound_email_from)
         ] ++ env_var_to_config!(:outbound_email_adapter_opts)

  config :portal,
         Portal.Mailer.Secondary,
         [
           adapter: env_var_to_config!(:secondary_outbound_email_adapter),
           from_email: env_var_to_config!(:outbound_email_from)
         ] ++ env_var_to_config!(:secondary_outbound_email_adapter_opts)

  config :portal,
         Portal.AzureCommunicationServices,
         event_grid_webhook_signing_secret:
           env_var_to_config!(:acs_event_grid_webhook_signing_secret)

  # Sentry

  with api_external_url when not is_nil(api_external_url) <-
         env_var_to_config!(:api_external_url),
       api_external_url_host <- URI.parse(api_external_url).host,
       environment_name when environment_name in [:staging, :production] <-
         (cond do
            String.contains?(api_external_url_host, "firezone.dev") -> :production
            String.contains?(api_external_url_host, "firez.one") -> :staging
            true -> :unknown
          end) do
    config :sentry,
      environment_name: environment_name,
      dsn: env_var_to_config!(:sentry_dsn)
  end
end
