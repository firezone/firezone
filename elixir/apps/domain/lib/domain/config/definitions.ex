defmodule Domain.Config.Definitions do
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
  use Domain.Config.Definition
  alias Domain.Config.Dumper
  alias Domain.Types
  alias Domain.Config.Logo

  if Mix.env() in [:test, :dev] do
    @local_development_adapters [Swoosh.Adapters.Local]
  else
    @local_development_adapters []
  end

  def doc_sections do
    [
      {"WebServer",
       [
         :external_url,
         :phoenix_secure_cookies,
         :phoenix_listen_address,
         :phoenix_http_web_port,
         :phoenix_http_api_port,
         :phoenix_http_protocol_options,
         :phoenix_external_trusted_proxies,
         :phoenix_private_clients
       ]},
      {"Database",
       [
         :database_host,
         :database_port,
         :database_name,
         :database_user,
         :database_password,
         :database_pool_size,
         :database_ssl_enabled,
         :database_ssl_opts,
         :database_parameters
       ]},
      {"Cloud Platform",
       [
         :platform_adapter,
         :platform_adapter_config
       ]},
      {"Erlang Cluster",
       [
         :erlang_cluster_adapter,
         :erlang_cluster_adapter_config
       ]},
      {"Secrets and Encryption",
       """
       Your secrets should be generated during installation automatically and persisted to `.env` file.

       All secrets should be a **base64-encoded string**.
       """,
       [
         :tokens_key_base,
         :tokens_salt,
         :relays_auth_token_key_base,
         :relays_auth_token_salt,
         :gateways_auth_token_key_base,
         :gateways_auth_token_salt,
         :secret_key_base,
         :live_view_signing_salt,
         :cookie_signing_salt,
         :cookie_encryption_salt
       ]},
      {"Clients",
       [
         :clients_upstream_dns
       ]},
      {"Authorization",
       """
       Providers:

        * `openid_connect` is used to authenticate users via OpenID Connect, this is recommended for production use;
        * `email` is used to authenticate users via sign in tokens sent to the email;
        * `token` is used to authenticate service accounts using an API token;
        * `userpass` is used to authenticate users with username and password, should be used
        with extreme care and is not recommended for production use.
       """,
       [
         :auth_provider_adapters
       ]},
      {"Gateways",
       [
         :gateway_ipv4_masquerade,
         :gateway_ipv6_masquerade
       ]},
      {"Outbound Emails",
       [
         :outbound_email_from,
         :outbound_email_adapter,
         :outbound_email_adapter_opts
       ]},
      {"Instrumentation",
       [
         :instrumentation_client_logs_enabled,
         :instrumentation_client_logs_bucket
       ]},
      {"Telemetry",
       [
         :telemetry_enabled,
         :telemetry_id
       ]}
    ]
  end

  ##############################################
  ## Web Server
  ##############################################

  @doc """
  The external URL the web UI will be accessible at.

  Must be a valid and public FQDN for ACME SSL issuance to function.

  You can add a path suffix if you want to serve firezone from a non-root path,
  eg: `https://firezone.mycorp.com/vpn/`.
  """
  defconfig(:external_url, :string,
    changeset: fn changeset, key ->
      changeset
      |> Domain.Validator.validate_uri(key, require_trailing_slash: true)
      |> Domain.Validator.normalize_url(key)
    end
  )

  @doc """
  Enable or disable requiring secure cookies. Required for HTTPS.
  """
  defconfig(:phoenix_secure_cookies, :boolean, default: true)

  defconfig(:phoenix_listen_address, Types.IP, default: "0.0.0.0")

  @doc """
  Internal port to listen on for the Phoenix web server.
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
  Internal port to listen on for the Phoenix api server.
  """
  defconfig(:phoenix_http_api_port, :integer,
    default: 13_000,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_number(changeset, key,
        greater_than: 0,
        less_than_or_equal_to: 65_535
      )
    end
  )

  @doc """
  Allows to override Cowboy HTTP server options.

  Keep in mind though changing those limits can pose a security risk. Other times,
  browsers and proxies along the way may have equally strict limits, which means
  the request will still fail or the URL will be pruned.

  You can see all supported options at https://ninenines.eu/docs/en/cowboy/2.5/manual/cowboy_http/.
  """
  defconfig(:phoenix_http_protocol_options, :map,
    default: %{max_header_value_length: 8192},
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
  PostgreSQL host.
  """
  defconfig(:database_host, :string, default: "postgres")

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
  Whether to connect to the database over SSL.

  If this field is set to `true`, the `database_ssl_opts` config must be set too
  with at least `cacertfile` option present.
  """
  defconfig(:database_ssl_enabled, :boolean, default: false)

  @doc """
  SSL options for connecting to the PostgreSQL database.

  Typically, to enabled SSL you want following options:

    * `cacertfile` - path to the CA certificate file;
    * `verify` - set to `verify_peer` to verify the server certificate;
    * `fail_if_no_peer_cert` - set to `true` to require the server to present a certificate;
    * `server_name_indication` - specify the hostname to be used in TLS Server Name Indication extension.

  See [Ecto.Adapters.Postgres documentation](https://hexdocs.pm/ecto_sql/Ecto.Adapters.Postgres.html#module-connection-options).
  For list of all supported options, see the [`ssl`](http://erlang.org/doc/man/ssl.html#type-tls_client_option) module documentation.
  """
  defconfig(:database_ssl_opts, :map,
    default: %{},
    dump: &Dumper.dump_ssl_opts/1
  )

  defconfig(:database_parameters, :map,
    default: %{application_name: "firezone-#{Application.spec(:domain, :vsn)}"},
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
    {:parameterized, Ecto.Enum,
     Ecto.Enum.init(
       values: [
         Elixir.Domain.GoogleCloudPlatform
       ]
     )},
    default: nil
  )

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
    {:parameterized, Ecto.Enum,
     Ecto.Enum.init(
       values: [
         Elixir.Cluster.Strategy.LocalEpmd,
         Elixir.Cluster.Strategy.Epmd,
         Elixir.Cluster.Strategy.Gossip,
         Elixir.Domain.Cluster.GoogleComputeLabelsStrategy
       ]
     )},
    default: nil
  )

  @doc """
  Config for the Erlang cluster adapter.
  """
  defconfig(:erlang_cluster_adapter_config, :map,
    default: %{},
    dump: fn map ->
      keyword = Dumper.keyword(map)

      if compile_config!(:erlang_cluster_adapter) == Elixir.Cluster.Strategy.Epmd do
        Keyword.update!(keyword, :hosts, fn hosts -> Enum.map(hosts, &String.to_atom/1) end)
      else
        keyword
      end
    end
  )

  ##############################################
  ## Secrets
  ##############################################

  @doc """
  Secret which is used to encode and sign tokens.
  """
  defconfig(:tokens_key_base, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Salt which is used to encode and sign tokens.
  """
  defconfig(:tokens_salt, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Secret which is used to encode and sign relays auth tokens.
  """
  defconfig(:relays_auth_token_key_base, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Salt which is used to encode and sign relays auth tokens.
  """
  defconfig(:relays_auth_token_salt, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Secret which is used to encode and sign gateways auth tokens.
  """
  defconfig(:gateways_auth_token_key_base, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Salt which is used to encode and sign gateways auth tokens.
  """
  defconfig(:gateways_auth_token_salt, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Primary secret key base for the Phoenix application.
  """
  defconfig(:secret_key_base, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Signing salt for Phoenix LiveView connection tokens.
  """
  defconfig(:live_view_signing_salt, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Signing salt for cookies issued by the Phoenix web application.
  """
  defconfig(:cookie_signing_salt, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Encryption salt for cookies issued by the Phoenix web application.
  """
  defconfig(:cookie_encryption_salt, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  ##############################################
  ## Clients
  ##############################################

  @doc """
  Comma-separated list of upstream DNS servers to use for clients.

  It can be one of the following:
    - IP address
    - FQDN if you intend to use a DNS-over-TLS server
    - URI if you intent to use a DNS-over-HTTPS server

  Leave this blank to omit the `DNS` section from generated configs,
  which will make clients use default system-provided DNS even when VPN session is active.
  """
  defconfig(
    :clients_upstream_dns,
    {:json_array, {:embed, Domain.Config.Configuration.ClientsUpstreamDNS},
     validate_unique: false},
    default: [],
    changeset: {Domain.Config.Configuration.ClientsUpstreamDNS, :changeset, []}
  )

  ##############################################
  ## Userpass / SAML / OIDC / Email authentication
  ##############################################

  @doc """
  Enable or disable the authentication methods for all users.

  It will affect on which auth providers can be created per an account but will not disable
  already active providers when setting is changed.
  """
  defconfig(
    :auth_provider_adapters,
    {:array, ",", {:parameterized, Ecto.Enum, Ecto.Enum.init(values: ~w[
      email
      openid_connect google_workspace
      userpass
      token
    ]a)}},
    default: ~w[email openid_connect google_workspace token]a
  )

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

  ##############################################
  ## Telemetry
  ##############################################

  @doc """
  Enable or disable the Firezone telemetry collection.

  For more details see https://docs.firezone.dev/reference/telemetry/.
  """
  defconfig(:telemetry_enabled, :boolean, default: true)

  defconfig(:telemetry_id, :string,
    default: fn ->
      :crypto.hash(:sha256, compile_config!(:external_url))
      |> Base.url_encode64(padding: false)
    end,
    legacy_keys: [{:env, "TID", nil}]
  )

  ##############################################
  ## Gateways
  ##############################################

  defconfig(:gateway_ipv4_masquerade, :boolean, default: true)
  defconfig(:gateway_ipv6_masquerade, :boolean, default: true)

  ##############################################
  ## HTTP Client Settings
  ##############################################

  defconfig(:http_client_ssl_opts, :map,
    default: %{},
    dump: &Dumper.dump_ssl_opts/1
  )

  ##############################################
  ## Outbound Email Settings
  ##############################################

  @doc """
  From address to use for sending outbound emails. If not set, sending email will be disabled (default).
  """
  defconfig(:outbound_email_from, :string,
    default: fn ->
      external_uri = URI.parse(compile_config!(:external_url))
      "firezone@#{external_uri.host}"
    end,
    sensitive: true,
    changeset: fn changeset, key ->
      changeset
      |> Domain.Validator.trim_change(key)
      |> Domain.Validator.validate_email(key)
    end
  )

  @doc """
  Method to use for sending outbound email. If not set, sending emails will be disabled (default).
  """
  defconfig(
    :outbound_email_adapter,
    {:parameterized, Ecto.Enum,
     Ecto.Enum.init(
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
     )},
    default: nil
  )

  @doc """
  Adapter configuration, for list of options see [Swoosh Adapters](https://github.com/swoosh/swoosh#adapters).
  """
  defconfig(:outbound_email_adapter_opts, :map,
    # TODO: validate opts are present if adapter is not NOOP one
    default: %{},
    sensitive: true,
    dump: &Dumper.keyword/1
  )

  ##############################################
  ## Appearance
  ##############################################

  @doc """
  The path to a logo image file to replace default Firezone logo.
  """
  defconfig(:logo, {:embed, Logo},
    default: nil,
    changeset: {Logo, :changeset, []}
  )

  ##############################################
  ## Local development and Staging Helpers
  ##############################################

  defconfig(:docker_registry, :string, default: "ghcr.io/firezone")
  defconfig(:api_url_override, :string, default: nil)

  ##############################################
  ## Feature Flags
  ##############################################

  @doc """
  Boolean flag to turn Sign-ups on/off.
  """
  defconfig(:feature_sign_up_enabled, :boolean, default: true)

  @doc """
  Boolean flag to turn UI flow activities on/off.
  """
  defconfig(:feature_flow_activities_enabled, :boolean, default: false)

  @doc """
  Boolean flag to turn Resource traffic filters on/off.
  """
  defconfig(:feature_traffic_filters_enabled, :boolean, default: false)

  @doc """
  Boolean flag to turn Relay Admin functionality on/off.
  """
  defconfig(:feature_self_hosted_relays_enabled, :boolean, default: false)
end
