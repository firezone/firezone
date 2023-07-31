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
         :auth_token_key_base,
         :auth_token_salt,
         :relays_auth_token_key_base,
         :relays_auth_token_salt,
         :gateways_auth_token_key_base,
         :gateways_auth_token_salt,
         :secret_key_base,
         :live_view_signing_salt,
         :cookie_signing_salt,
         :cookie_encryption_salt
       ]},
      {"Devices",
       [
         :devices_upstream_dns
       ]},
      {"Authorization",
       """
       Providers:

        * `openid_connect` is used to authenticate users via OpenID Connect, this is recommended for production use;
        * `email` is used to authenticate users via magic links sent to the email;
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
  defconfig(:phoenix_secure_cookies, :boolean,
    default: true,
    legacy_keys: [{:env, "SECURE_COOKIES", "0.9"}]
  )

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
    default: [],
    legacy_keys: [{:env, "EXTERNAL_TRUSTED_PROXIES", "0.9"}]
  )

  @doc """
  List of trusted clients.

  This is used to determine the correct IP address of the client when the
  application is behind a reverse proxy by picking a trusted client IP
  from a list of possible source IPs.
  """
  defconfig(:phoenix_private_clients, {:json_array, {:one_of, [Types.IP, Types.CIDR]}},
    default: [],
    legacy_keys: [{:env, "PRIVATE_CLIENTS", "0.9"}]
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
    default: fn -> :erlang.system_info(:logical_processors_available) * 2 end,
    legacy_keys: [{:env, "DATABASE_POOL", "0.9"}]
  )

  @doc """
  Whether to connect to the database over SSL.

  If this field is set to `true`, the `database_ssl_opts` config must be set too
  with at least `cacertfile` option present.
  """
  defconfig(:database_ssl_enabled, :boolean,
    default: false,
    legacy_keys: [{:env, "DATABASE_SSL", "0.9"}]
  )

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
  ## Erlang Cluster
  ##############################################

  @doc """
  An adapter that will be used to discover and connect nodes to the Erlang cluster.

  Set to `Domain.Cluster.Local` to disable
  """
  defconfig(
    :erlang_cluster_adapter,
    {:parameterized, Ecto.Enum,
     Ecto.Enum.init(
       values: [
         Elixir.Cluster.Strategy.LocalEpmd,
         Elixir.Cluster.Strategy.Epmd,
         Elixir.Cluster.Strategy.Gossip,
         Elixir.Domain.Cluster.GoogleComputeLabelsStrategy,
         Domain.Cluster.Local
       ]
     )},
    default: Domain.Cluster.Local
  )

  @doc """
  Config for the Erlang cluster adapter.
  """
  defconfig(:erlang_cluster_adapter_config, :map,
    default: [],
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
  Secret which is used to encode and sign auth tokens.
  """
  defconfig(:auth_token_key_base, :string,
    sensitive: true,
    changeset: &Domain.Validator.validate_base64/2
  )

  @doc """
  Salt which is used to encode and sign auth tokens.
  """
  defconfig(:auth_token_salt, :string,
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
  ## Devices
  ##############################################

  @doc """
  Comma-separated list of upstream DNS servers to use for devices.

  It can be either an IP address or a FQDN if you intend to use a DNS-over-TLS server.

  Leave this blank to omit the `DNS` section from generated configs,
  which will make devices use default system-provided DNS even when VPN session is active.
  """
  defconfig(
    :devices_upstream_dns,
    {:array, ",", {:one_of, [Types.IP, :string]}, validate_unique: true},
    default: [],
    changeset: fn
      Types.IP, changeset, _key ->
        changeset

      :string, changeset, key ->
        changeset
        |> Domain.Validator.trim_change(key)
        |> Domain.Validator.validate_fqdn(key)
    end
  )

  ##############################################
  ## Userpass / SAML / OIDC / Magic Link authentication
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
       values: [
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
       ]
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
    legacy_keys: [{:env, "OUTBOUND_EMAIL_CONFIGS", "0.9"}],
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
end
