defmodule Portal.Config.Definitions do
  @moduledoc """
  Most day-to-day config of Firezone can be done via the Firezone Web UI,
  but for zero-touch deployments we allow to override most of configuration options
  using environment variables.

  Read more about configuring Firezone in our [configure guide](/docs/deploy/configure).

  ## Errors

  Firezone will not boot if the configuration is invalid, providing a detailed error message
  and a link to the documentation for the configuration key with samples how to set it.

  ## Naming

  If environment variables are used, the configuration key must be in uppercase.
  The database variables are the same as the configuration keys.

  ## Precedence

  The configuration precedence is as follows:

  1. Environment variables
  2. Database values
  3. Default values

  It means that if environment variable is set, it will be used, regardless of the database value,
  and UI to edit database value will be disabled.
  """
  use Portal.Config.Definition
  alias Portal.Config.Dumper
  alias Portal.Types

  @entra_sync_client_id ""
  @google_oidc_client_id "689429116054-72vkp65pqrntsq3bksj9bt4pft15if4v.apps.googleusercontent.com"
  @entra_oidc_client_id "d0b74799-63b8-4c10-8255-1c03c48a3029"

  if Mix.env() in [:test, :dev] do
    @local_development_adapters [Swoosh.Adapters.Local]
  else
    @local_development_adapters []
  end

  ##############################################
  ## Background Jobs
  ##############################################

  @doc """
  Enabled or disable background job workers (eg. syncing IdP directory) for the app instance.
  """
  defconfig(:background_jobs_enabled, :boolean, default: false)

  ##############################################
  ## Web Server
  ##############################################

  @doc """
  The external URL the UI will be accessible at.

  If this field is not set or set to `nil`, the server for `api` and `web` apps will not start.
  """
  defconfig(:web_external_url, :string,
    default: nil,
    changeset: fn changeset, key ->
      changeset
      |> Portal.Changeset.validate_uri(key, require_trailing_slash: true)
      |> Portal.Changeset.normalize_url(key)
    end
  )

  @doc """
  The external URL the API will be accessible at.

  If this field is not set or set to `nil`, the server for `api` and `web` apps will not start.
  """

  defconfig(:api_external_url, :string,
    default: nil,
    changeset: fn changeset, key ->
      changeset
      |> Portal.Changeset.validate_uri(key, require_trailing_slash: true)
      |> Portal.Changeset.normalize_url(key)
    end
  )

  @doc """
  The API rate limiter uses a token bucket algorithm. This field sets the rate the bucket is refilled.
  """
  defconfig(:api_refill_rate, :integer, default: 10)

  @doc """
  The API rate limiter uses a token bucket algorithm. This field sets the capacity of the bucket.
  """
  defconfig(:api_capacity, :integer, default: 200)

  @doc """
  Enable or disable requiring secure cookies. Required for HTTPS.
  """
  defconfig(:phoenix_secure_cookies, :boolean, default: true)

  defconfig(:phoenix_listen_address, Types.IP, default: "0.0.0.0")

  @doc """
  Internal port to listen on for the Phoenix server for the `web` application.
  """
  defconfig(:phoenix_http_web_port, :integer,
    default: 13_000,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_number(changeset, key,
        greater_than: 0,
        less_than_or_equal_to: 65_535
      )
    end
  )

  @doc """
  Internal port to listen on for the Phoenix server for the `api` application.
  """
  defconfig(:phoenix_http_api_port, :integer,
    default: 13_001,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_number(changeset, key,
        greater_than: 0,
        less_than_or_equal_to: 65_535
      )
    end
  )

  @doc """
  Allows to override Bandit HTTP/1.1 server options.

  These options are passed to Bandit's `http_1_options`. Keep in mind that changing
  these limits can pose a security risk. Browsers and proxies along the way may have
  equally strict limits, which means the request will still fail or the URL will be pruned.

  You can see all supported options at https://hexdocs.pm/bandit/Bandit.html#t:http_1_options/0.

  Note: Bandit's default max_header_length (combined key & value per header) is 10000 bytes,
  compared to Cowboy's max_header_value_length which was 4096 bytes (value only).
  """
  defconfig(:phoenix_http_protocol_options, :map,
    default: %{},
    dump: &Dumper.keyword/1
  )

  @doc """
  List of trusted reverse proxies.

  This is used to determine the correct IP address of the client when the
  application is behind a reverse proxy by skipping a trusted proxy IP
  from a list of possible source IPs.
  """
  defconfig(:phoenix_external_trusted_proxies, {:json_array, {:one_of, [Types.IP, Types.CIDR]}},
    default: []
  )

  @doc """
  List of trusted clients.

  This is used to determine the correct IP address of the client when the
  application is behind a reverse proxy by picking a trusted client IP
  from a list of possible source IPs.
  """
  defconfig(:phoenix_private_clients, {:json_array, {:one_of, [Types.IP, Types.CIDR]}},
    default: []
  )

  ##############################################
  ## Database
  ##############################################

  @doc """
  Whether to run migrations in the priv/repo/manual_migrations directory.
  If set to false, these migrations must be manually run from an IEx shell.
  """
  defconfig(:run_manual_migrations, :boolean, default: false)

  @doc """
  PostgreSQL host.
  """
  defconfig(:database_host, :string, default: "postgres")

  @doc """
  PostgreSQL replica host for read-only queries.
  Falls back to DATABASE_HOST if not set.
  """
  defconfig(:database_host_replica, :string,
    default: fn -> System.get_env("DATABASE_HOST", "postgres") end
  )

  @doc """
  PostgreSQL socket directory (takes precedence over hostname).
  """
  defconfig(:database_socket_dir, :string, default: nil)

  @doc """
  PostgreSQL port.
  """
  defconfig(:database_port, :integer, default: 5432)

  @doc """
  Name of the PostgreSQL database.
  """
  defconfig(:database_name, :string, default: "firezone")

  @doc """
  User that will be used to access the PostgreSQL database.
  """
  defconfig(:database_user, :string, default: "postgres", sensitive: true)

  @doc """
  Password that will be used to access the PostgreSQL database.
  """
  defconfig(:database_password, :string, default: nil, sensitive: true)

  @doc """
  Size of the connection pool to the PostgreSQL database.
  """
  defconfig(:database_pool_size, :integer,
    default: fn -> :erlang.system_info(:logical_processors_available) * 2 end
  )

  @doc """
  The target threshold for the length of time in milliseconds that a query should wait in the queue
  """
  defconfig(:database_queue_target, :integer, default: 500)

  @doc """
  How often to check for queries that exceeded 2 * `database_queue_target` milliseconds
  """
  defconfig(:database_queue_interval, :integer, default: 1000)

  @doc """
  Socket options for database connections.

  These options are passed to the underlying TCP socket. The most important option is
  `keepalive: true` which enables TCP keepalive probes to detect dead connections.

  Without keepalive, connections can become "zombies" when the database server becomes
  unavailable (e.g., during Azure platform maintenance), causing queries to hang until
  the checkout timeout is reached.

  Accepts a JSON object with socket options (e.g. `{"keepalive": true}`).
  """
  defconfig(:database_socket_options, :map,
    default: %{},
    dump: &Dumper.keyword/1
  )

  @doc """
  Name of the replication slot used by Firezone.
  """
  defconfig(:database_changes_replication_slot_name, :string, default: "changes_slot")

  @doc """
  Name of the publication used by Firezone.
  """
  defconfig(:database_changes_publication_name, :string, default: "changes")

  @doc """
  Name of the replication slot used by Firezone.
  """
  defconfig(:database_change_logs_replication_slot_name, :string, default: "change_logs_slot")

  @doc """
  Name of the publication used by Firezone.
  """
  defconfig(:database_change_logs_publication_name, :string, default: "change_logs")

  @doc """
  SSL configuration for database connections.

  Accepts:
  - `false` - SSL disabled
  - `true` - SSL enabled with default options
  - A JSON object with SSL options (e.g. `{"cacertfile": "/path/to/cert", "verify": "verify_peer"}`)

  When a JSON object is provided, the options are passed directly to Postgrex's `:ssl` option.
  Supported SSL options: `cacertfile`, `verify`, `depth`, `versions`, `server_name_indication`.
  """
  defconfig(:database_ssl, :boolean_or_map,
    default: false,
    dump: fn
      false -> false
      true -> true
      %{} = opts when map_size(opts) == 0 -> false
      %{} = opts -> Dumper.dump_ssl_opts(opts)
    end
  )

  defconfig(:database_parameters, :map,
    default: %{application_name: "firezone-#{Application.spec(:portal, :vsn)}"},
    dump: &Dumper.keyword/1
  )

  ##############################################
  ## Platform
  ##############################################

  @doc """
  Cloud platform on which the Firezone runs on which is used to unlock
  platform-specific features (logging, tracing, monitoring, clustering).
  """
  defconfig(
    :platform_adapter,
    Ecto.ParameterizedType.init(Ecto.Enum,
      values: [
        Elixir.Portal.GoogleCloudPlatform
      ]
    ),
    default: nil
  )

  @doc """
  Azure Front Door ID (GUID format) for validating the X-Azure-FDID header.

  When set, requests without a matching X-Azure-FDID header will be rejected with 502.
  This prevents other Azure Front Door instances from sending traffic to this application.
  """
  defconfig(:azure_front_door_id, :string, default: nil)

  @doc """
  Config for the platform adapter.
  """
  defconfig(:platform_adapter_config, :map,
    default: [],
    dump: &Dumper.keyword/1
  )

  ##############################################
  ## Erlang Cluster
  ##############################################

  @doc """
  An adapter that will be used to discover and connect nodes to the Erlang cluster.
  """
  defconfig(
    :erlang_cluster_adapter,
    Ecto.ParameterizedType.init(Ecto.Enum,
      values: [
        Elixir.Cluster.Strategy.LocalEpmd,
        Elixir.Cluster.Strategy.Epmd,
        Elixir.Cluster.Strategy.Gossip,
        Elixir.Cluster.Strategy.Kubernetes,
        Elixir.Cluster.Strategy.DNSPoll,
        Elixir.Portal.Cluster.GoogleComputeLabelsStrategy,
        Elixir.Portal.Cluster.PostgresStrategy
      ]
    ),
    default: nil
  )

  @doc """
  Config for the Erlang cluster adapter.
  """
  defconfig(:erlang_cluster_adapter_config, :map,
    default: %{},
    dump: fn map ->
      dump_cluster_adapter_config(map, env_var_to_config!(:erlang_cluster_adapter))
    end
  )

  @doc """
  A secondary adapter for cluster discovery, useful during rolling deploys when migrating
  between clustering strategies. Both adapters run simultaneously and nodes discovered
  by either mechanism will be connected.
  """
  defconfig(
    :erlang_cluster_adapter_secondary,
    Ecto.ParameterizedType.init(Ecto.Enum,
      values: [
        Elixir.Cluster.Strategy.LocalEpmd,
        Elixir.Cluster.Strategy.Epmd,
        Elixir.Cluster.Strategy.Gossip,
        Elixir.Cluster.Strategy.Kubernetes,
        Elixir.Cluster.Strategy.DNSPoll,
        Elixir.Portal.Cluster.GoogleComputeLabelsStrategy,
        Elixir.Portal.Cluster.PostgresStrategy
      ]
    ),
    default: nil
  )

  @doc """
  Config for the secondary Erlang cluster adapter.
  """
  defconfig(:erlang_cluster_adapter_secondary_config, :map,
    default: %{},
    dump: fn map ->
      dump_cluster_adapter_config(map, env_var_to_config!(:erlang_cluster_adapter_secondary))
    end
  )

  defp dump_cluster_adapter_config(map, adapter) do
    keyword = Dumper.keyword(map)

    cond do
      adapter == Elixir.Cluster.Strategy.Epmd ->
        Keyword.update!(keyword, :hosts, fn hosts -> Enum.map(hosts, &String.to_atom/1) end)

      adapter == Elixir.Cluster.Strategy.Kubernetes ->
        Keyword.new(keyword, fn
          {k, v} when k in [:mode, :kubernetes_ip_lookup_mode] -> {k, String.to_atom(v)}
          {k, v} -> {k, v}
        end)

      adapter == Elixir.Portal.Cluster.PostgresStrategy ->
        Keyword.new(keyword, fn
          {:repo, v} -> {:repo, Module.concat([v])}
          {k, v} -> {k, v}
        end)

      true ->
        keyword
    end
  end

  ##############################################
  ## Secrets
  ##############################################

  @doc """
  Secret which is used to encode and sign tokens.
  """
  defconfig(:tokens_key_base, :string,
    sensitive: true,
    changeset: &Portal.Changeset.validate_base64/2
  )

  @doc """
  Salt which is used to encode and sign tokens.
  """
  defconfig(:tokens_salt, :string,
    sensitive: true,
    changeset: &Portal.Changeset.validate_base64/2
  )

  @doc """
  Primary secret key base for the Phoenix application.
  """
  defconfig(:secret_key_base, :string,
    sensitive: true,
    changeset: &Portal.Changeset.validate_base64/2
  )

  @doc """
  Signing salt for Phoenix LiveView connection tokens.
  """
  defconfig(:live_view_signing_salt, :string,
    sensitive: true,
    changeset: &Portal.Changeset.validate_base64/2
  )

  @doc """
  Signing salt for cookies issued by the Phoenix web application.
  """
  defconfig(:cookie_signing_salt, :string,
    sensitive: true,
    changeset: &Portal.Changeset.validate_base64/2
  )

  @doc """
  Encryption salt for cookies issued by the Phoenix web application.
  """
  defconfig(:cookie_encryption_salt, :string,
    sensitive: true,
    changeset: &Portal.Changeset.validate_base64/2
  )

  ##############################################
  ## Userpass / SAML / OIDC / Email authentication
  ##############################################

  @doc """
  Enable or disable the authentication methods for all users.

  It will affect on which auth providers can be created per an account but will not disable
  already active providers when setting is changed.
  """
  # TODO: IdP refactor
  # Remove google / okta / entra / jumpcloud
  defconfig(
    :auth_provider_adapters,
    {:array, ",", Ecto.ParameterizedType.init(Ecto.Enum, values: ~w[
      email
      openid_connect
      google_workspace
      microsoft_entra
      okta
      jumpcloud
      mock
      userpass
      token
    ]a)},
    default: ~w[
      email
      openid_connect
      google_workspace
      microsoft_entra
      okta
      jumpcloud
      mock
      token
    ]a
  )

  ##############################################
  ## Directory Sync
  ##############################################

  defconfig(:google_service_account_key, :string, default: nil, sensitive: true)

  ##############################################
  ## Google / Entra / Okta authentication
  ##############################################

  defconfig(:google_oidc_client_id, :string, default: @google_oidc_client_id)
  defconfig(:google_oidc_client_secret, :string, default: nil, sensitive: true)

  defconfig(:entra_sync_client_id, :string, default: @entra_sync_client_id)
  defconfig(:entra_sync_client_secret, :string, default: nil, sensitive: true)

  defconfig(:entra_oidc_client_id, :string, default: @entra_oidc_client_id)
  defconfig(:entra_oidc_client_secret, :string, default: nil, sensitive: true)

  # Okta uses a per-tenant client_id/secret

  ##############################################
  ## Health
  ##############################################

  @doc """
  The port for the internal health endpoint.
  """
  defconfig(:health_port, :integer,
    default: 4000,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_number(changeset, key,
        greater_than: 0,
        less_than_or_equal_to: 65_535
      )
    end
  )

  @doc """
  Path to the file that signals the service is draining.

  When this file exists, the `/readyz` endpoint will return 503 with status "draining".
  """
  defconfig(:draining_file_path, :string, default: "/var/run/firezone/draining")

  ##############################################
  ## Telemetry
  ##############################################

  @doc """
  Enable or disable the Firezone telemetry collection.

  For more details see https://docs.firezone.dev/reference/telemetry/.
  """
  defconfig(:instrumentation_client_logs_enabled, :boolean, default: true)

  @doc """
  Name of the bucket to store client-, relay- and gateway-submitted instrumentation logs in.
  """
  defconfig(:instrumentation_client_logs_bucket, :string, default: "logs")

  @doc """
  Reporter to use for sending metrics to the telemetry backend.
  """
  defconfig(
    :telemetry_metrics_reporter,
    Ecto.ParameterizedType.init(Ecto.Enum,
      values: [
        Telemetry.Metrics.ConsoleReporter,
        Elixir.Portal.Telemetry.Reporter.GoogleCloudMetrics
      ]
    ),
    default: nil
  )

  @doc """
  Configuration for the telemetry metrics reporter.
  """
  defconfig(:telemetry_metrics_reporter_opts, :map,
    default: %{},
    dump: &Dumper.keyword/1
  )

  ##############################################
  ## HTTP Client Settings
  ##############################################

  defconfig(:http_client_ssl_opts, :map,
    default: %{},
    dump: &Dumper.dump_ssl_opts/1
  )

  ##############################################
  ## Geolocation
  ##############################################

  @doc """
  Path to the MaxMind GeoLite2-City database file (MMDB format).

  Used for IP geolocation lookups. Download from https://dev.maxmind.com/geoip/geolite2-free-geolocation-data
  (requires free account).
  """
  defconfig(:maxmind_city_db_path, :string, default: nil)

  ##############################################
  ## Outbound Email Settings
  ##############################################

  @doc """
  From address to use for sending outbound emails. If not set, sending email will be disabled (default).
  """
  defconfig(:outbound_email_from, :string,
    default: fn ->
      external_uri = URI.parse(env_var_to_config!(:web_external_url))
      "firezone@#{external_uri.host}"
    end,
    sensitive: true,
    changeset: fn changeset, key ->
      changeset
      |> Portal.Changeset.trim_change(key)
      |> Portal.Changeset.validate_email(key)
    end
  )

  @doc """
  Method to use for sending outbound email. If not set, sending emails will be disabled (default).
  """
  defconfig(
    :outbound_email_adapter,
    Ecto.ParameterizedType.init(Ecto.Enum,
      values:
        [
          Swoosh.Adapters.AmazonSES,
          Swoosh.Adapters.CustomerIO,
          Swoosh.Adapters.Dyn,
          Swoosh.Adapters.ExAwsAmazonSES,
          Swoosh.Adapters.Gmail,
          Swoosh.Adapters.MailPace,
          Swoosh.Adapters.Mailgun,
          Swoosh.Adapters.Mailjet,
          Swoosh.Adapters.Mandrill,
          Swoosh.Adapters.Postmark,
          Swoosh.Adapters.ProtonBridge,
          Swoosh.Adapters.SMTP,
          Swoosh.Adapters.SMTP2GO,
          Swoosh.Adapters.Sendgrid,
          Swoosh.Adapters.Sendinblue,
          Swoosh.Adapters.Sendmail,
          Swoosh.Adapters.SocketLabs,
          Swoosh.Adapters.SparkPost
        ] ++ @local_development_adapters
    ),
    default: nil
  )

  @doc """
  Adapter configuration, for list of options see [Swoosh Adapters](https://github.com/swoosh/swoosh#adapters).
  """
  defconfig(:outbound_email_adapter_opts, :map,
    default: %{},
    sensitive: true,
    dump: fn map ->
      Dumper.keyword(map)
      |> Keyword.update(:tls_options, nil, &Dumper.dump_ssl_opts/1)
      |> Keyword.update(:sockopts, [], &Dumper.dump_ssl_opts/1)
    end
  )

  ##############################################
  ## Billing flags
  ##############################################

  defconfig(:billing_enabled, :boolean, default: false)
  defconfig(:stripe_secret_key, :string, sensitive: true, default: nil)
  defconfig(:stripe_webhook_signing_secret, :string, sensitive: true, default: nil)
  defconfig(:stripe_default_price_id, :string, default: nil)
  defconfig(:stripe_plan_product_ids, {:json_array, :string}, default: [])
  defconfig(:stripe_adhoc_device_product_id, :string, default: nil)

  ##############################################
  ## Local development and Staging Helpers
  ##############################################

  defconfig(:docker_registry, :string, default: "ghcr.io/firezone")
  defconfig(:api_url_override, :string, default: nil)

  ##############################################
  ## Feature Flags
  ##
  ## If feature is disabled globally it won't be available for any account,
  ## even if account-specific override enables them.
  ##
  ##############################################

  @doc """
  Boolean flag to turn Sign-ups on/off for all accounts.
  """
  defconfig(:feature_sign_up_enabled, :boolean, default: true)

  @doc """
  List of email domains allowed to signup from. Leave empty to allow signing up from any domain.
  """
  defconfig(:sign_up_whitelisted_domains, {:array, ",", :string},
    default: [],
    changeset: fn changeset, key ->
      changeset
      |> Ecto.Changeset.validate_required(key)
      |> Portal.Changeset.validate_fqdn(key)
    end
  )

  @doc """
  Boolean flag to turn IdP sync on/off for all accounts.
  """
  defconfig(:feature_idp_sync_enabled, :boolean, default: true)

  @doc """
  Boolean flag to turn Policy Conditions functionality on/off for all accounts.
  """
  defconfig(:feature_policy_conditions_enabled, :boolean, default: false)

  @doc """
  Boolean flag to turn Multi-Site resources functionality on/off for all accounts.
  """
  defconfig(:feature_multi_site_resources_enabled, :boolean, default: false)

  @doc """
  Boolean flag to turn API Client UI functionality on/off for all accounts.
  """
  defconfig(:feature_rest_api_enabled, :boolean, default: false)

  @doc """
  Boolean flag to turn Internet Resources functionality on/off for all accounts.
  """
  defconfig(:feature_internet_resource_enabled, :boolean, default: false)
end
