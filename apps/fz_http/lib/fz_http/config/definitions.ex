defmodule FzHttp.Config.Definitions do
  use FzHttp.Config.Definition
  alias FzHttp.Types
  alias FzHttp.Configurations.Configuration

  def doc_sections,
    do: [
      {"WebServer", [:external_url]},
      {"Admin Setup",
       "Options responsible for initial admin provisioning and resetting the admin password.",
       [
         :default_admin_email,
         :default_admin_password
       ]},
      {"Secrets",
       [
         :guardian_secret_key,
         :database_encryption_key,
         :secret_key_base,
         :live_view_signing_salt,
         :cookie_signing_salt,
         :cookie_encryption_salt
       ]}
    ]

  ##############################################
  ## Web Server
  ##############################################

  @doc """
  The external URL the web UI will be accessible at.

  Must be a valid and public FQDN for ACME SSL issuance to function.

  You can add a path suffix if you want to serve firezone from a non-root path,
  eg: `https://firezone.mycorp.com/vpn`.
  """
  defconfig(:external_url, :string, changeset: &FzHttp.Validator.validate_uri/2)

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
  defconfig(:phoenix_port, :integer,
    default: 13000,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_number(changeset, key,
        greater_than: 0,
        less_than_or_equal_to: 65_535
      )
    end
  )

  @doc """
  List of trusted reverse proxies.

  This is used to determine the correct IP address of the client when the
  application is behind a reverse proxy by skipping a trusted proxy IP
  from a list of possible source IPs.
  """
  defconfig(:phoenix_external_trusted_proxies, {:array, ",", {:one_of, [Types.IP, Types.CIDR]}},
    default: [],
    legacy_keys: [{:env, "EXTERNAL_TRUSTED_PROXIES", "0.9"}]
  )

  @doc """
  List of trusted clients.

  This is used to determine the correct IP address of the client when the
  application is behind a reverse proxy by picking a trusted client IP
  from a list of possible source IPs.
  """
  defconfig(:phoenix_private_clients, {:array, ",", {:one_of, [Types.IP, Types.CIDR]}},
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
  defconfig(:database_user, :string, default: "postgres")

  @doc """
  Password that will be used to access the PostgreSQL database.
  """
  defconfig(:database_password, :string)

  @doc """
  Size of the connection pool to the PostgreSQL database.
  """
  defconfig(:database_pool_size, :integer,
    default: 10,
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
    changeset: fn changeset, _key ->
      %{
        changeset
        | changes: %{
            changeset.changes
            | database_ssl_opts: FzCommon.map_ssl_opts(changeset.changes.database_ssl_opts)
          }
      }
    end
  )

  defconfig(:database_parameters, :map,
    default: %{application_name: "firezone-#{Application.spec(:fz_http, :vsn)}"}
  )

  ##############################################
  ## Admin Setup
  ##############################################

  @doc """
  Primary administrator email.
  """
  defconfig(:default_admin_email, :string,
    default: nil,
    legacy_keys: [{:env, "ADMIN_EMAIL", "0.9"}],
    changeset: &FzHttp.Validator.validate_email/2
  )

  @doc """
  Default password that will be used for creating or resetting the primary administrator account.
  """
  defconfig(:default_admin_password, :string,
    default: nil,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_length(changeset, key, min: 5)
    end
  )

  ##############################################
  ## Secrets
  ##############################################

  @doc """
  Secret key used for signing JWTs.
  """
  defconfig(:guardian_secret_key, :string, changeset: &FzHttp.Validator.validate_base64/2)

  @doc """
  Secret key used for encrypting sensitive data in the database.
  """
  defconfig(:database_encryption_key, :string, changeset: &FzHttp.Validator.validate_base64/2)

  @doc """
  Primary secret key base for the Phoenix application.
  """
  defconfig(:secret_key_base, :string, changeset: &FzHttp.Validator.validate_base64/2)

  @doc """
  Signing salt for Phoenix LiveView connection tokens.
  """
  defconfig(:live_view_signing_salt, :string, changeset: &FzHttp.Validator.validate_base64/2)

  @doc """
  Encryption salt for cookies issued by the Phoenix web application.
  """
  defconfig(:cookie_signing_salt, :string, changeset: &FzHttp.Validator.validate_base64/2)

  @doc """
  Signing salt for cookies issued by the Phoenix web application.
  """
  defconfig(:cookie_encryption_salt, :string, changeset: &FzHttp.Validator.validate_base64/2)

  ##############################################
  ## Devices
  ##############################################

  @doc """
  Enable or disable management of devices on unprivileged accounts.
  """
  defconfig(:allow_unprivileged_device_management, :boolean, default: true)

  @doc """
  Enable or disable configuration of device network settings for unprivileged users.
  """
  defconfig(:allow_unprivileged_device_configuration, :boolean, default: true)

  @doc """
  Optionally require users to periodically authenticate to the Firezone web UI in order to keep their VPN sessions active.
  """
  defconfig(:vpn_session_duration, :integer,
    default: 0,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_number(changeset, key,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 2_147_483_647
      )
    end
  )

  @doc """
  Interval for WireGuard [persistent keepalive](https://www.wireguard.com/quickstart/#nat-and-firewall-traversal-persistence).

  If you experience NAT or firewall traversal problems, you can enable this to send a keepalive packet every 25 seconds.
  Otherwise, keep it disabled with a 0 default value.
  """
  defconfig(:default_client_persistent_keepalive, :integer,
    default: 25,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_number(changeset, key,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 120
      )
    end
  )

  @doc """
  WireGuard interface MTU for devices. 1280 is a safe bet for most networks.
  Leave this blank to omit this field from generated configs.
  """
  defconfig(:default_client_mtu, :integer,
    default: 1280,
    legacy_keys: [{:env, "WIREGUARD_MTU", "0.8"}],
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_number(changeset, key,
        greater_than_or_equal_to: 576,
        less_than_or_equal_to: 1500
      )
    end
  )

  @doc """
  IPv4, IPv6 address, or FQDN that devices will be configured to connect to. Defaults to this server's FQDN.
  """
  defconfig(:default_client_endpoint, {:one_of, [Types.IPPort, :string]},
    default: fn ->
      external_uri = URI.parse(compile_config!(:external_url))
      wireguard_port = compile_config!(:wireguard_port)
      "#{external_uri.host}:#{wireguard_port}"
    end,
    changeset: fn
      Types.IPPort, changeset, _key ->
        changeset

      :string, changeset, key ->
        FzHttp.Validator.validate_fqdn(changeset, key, allow_port: true)
    end
  )

  @doc """
  Comma-separated list of DNS servers to use for devices.

  Leave this blank to omit the <code>DNS</code> section from
  generated configs.
  """
  defconfig(:default_client_dns, {:array, ",", Types.IP})

  @doc """
  Configures the default AllowedIPs setting for devices.

  AllowedIPs determines which destination IPs get routed through Firezone.

  Specify a comma-separated list of IPs or CIDRs here to achieve split tunneling, or use
  <code>0.0.0.0/0, ::/0</code> to route all device traffic through this Firezone server.
  """
  defconfig(:default_client_allowed_ips, {:array, ",", {:one_of, [Types.CIDR, Types.IP]}},
    default: "0.0.0.0/0,::/0"
  )

  ##############################################
  ## Limits
  ##############################################

  defconfig(:max_devices_per_user, :integer, default: 10)

  ##############################################
  ## Userpass / SAML / OIDC authentication
  ##############################################

  @doc """
  Enable or disable the local authentication method for all users.
  """
  defconfig(:local_auth_enabled, :boolean, default: true)

  @doc """
  Enable or disable auto disabling VPN connection on OIDC refresh error.
  """
  defconfig(:disable_vpn_on_oidc_error, :boolean, default: false)

  @doc """
  Entity ID for SAML authentication.
  """
  defconfig(:saml_entity_id, :string, default: "urn:firezone.dev:firezone-app")

  @doc """
  Path to the SAML keyfile inside the container.
  """
  defconfig(:saml_keyfile_path, :string,
    default: "/var/firezone/saml.key",
    changeset: &FzHttp.Validator.validate_file(&1, &2, extensions: ~w[.crt .pem])
  )

  @doc """
  Path to the SAML certificate file inside the container.
  """
  defconfig(:saml_certfile_path, :string,
    default: "/var/firezone/saml.crt",
    changeset: &FzHttp.Validator.validate_file(&1, &2, extensions: ~w[.crt .pem])
  )

  @doc """
  List of OpenID Connect identity providers configurations.

  For example:

      [
        {
          "auto_create_users": false,

          "id": "google",
          "label": "google",
          "client_id": "test-id",
          "client_secret": "test-secret",
          "discovery_document_uri": "https://accounts.google.com/.well-known/openid-configuration",
          "redirect_uri": "https://invalid",
          "response_type": "response-type",
          "scope": "oauth email profile"
        }
      ]


  For more details see https://docs.firezone.dev/authenticate/oidc/.
  """
  defconfig(:openid_connect_providers, {:array, {:embed, Configuration.OpenIDConnectProvider}},
    default: [],
    changeset: fn changeset, key ->
      Ecto.Changeset.cast_embed(changeset, key,
        with: {Configuration.OpenIDConnectProvider, :changeset, []}
      )
    end
  )

  @doc """
  List of SAML identity providers configurations.

  For example:

    [
      {
        "auto_create_users": false,

        "base_url": "https://saml",
        "id": "okta",
        "label": "okta",
        "metadata": "<?xml version="1.0"?>...",
        "sign_metadata": false,
        "sign_requests": false,
        "signed_assertion_in_resp": false,
        "signed_envelopes_in_resp": false
      }
    ]

  For more details see https://docs.firezone.dev/reference/saml/.
  """
  defconfig(:saml_identity_providers, {:array, {:embed, Configuration.SAMLIdentityProvider}},
    default: [],
    changeset: fn changeset, key ->
      Ecto.Changeset.cast_embed(changeset, key,
        with: {Configuration.SAMLIdentityProvider, :changeset, []}
      )
    end
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
  ## Connectivity Checks
  ##############################################

  @doc """
  Enable / disable periodic checking for egress connectivity. Determines the instance's public IP to populate `Endpoint` fields.
  """
  defconfig(:connectivity_checks_enabled, :boolean, default: true)

  @spec connectivity_checks_interval :: {:integer, [{:default, 3600}, ...]}
  @doc """
  Periodicity in seconds to check for egress connectivity.
  """
  defconfig(:connectivity_checks_interval, :integer, default: 3600)

  ##############################################
  ## WireGuard
  ##############################################

  defconfig(:wireguard_port, :integer,
    default: 51820,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_number(changeset, key,
        greater_than: 0,
        less_than_or_equal_to: 65_535
      )
    end
  )

  defconfig(:wireguard_egress_interface, :string,
    legacy_keys: [{:env, "EGRESS_INTERFACE", "0.8"}],
    default: "eth0"
  )

  defconfig(:wireguard_ipv4_enabled, :boolean, default: true)
  defconfig(:wireguard_ipv4_masquerade, :boolean, default: true)

  defconfig(:wireguard_ipv4_network, Types.CIDR,
    default: "10.3.2.0/24",
    changeset: &FzHttp.Validator.validate_ip_type_inclusion(&1, &2, [:ipv4])
  )

  defconfig(:wireguard_ipv4_address, Types.IP,
    default: "10.3.2.1",
    changeset: &FzHttp.Validator.validate_ip_type_inclusion(&1, &2, [:ipv4])
  )

  defconfig(:wireguard_ipv6_enabled, :boolean, default: true)
  defconfig(:wireguard_ipv6_masquerade, :boolean, default: true)

  defconfig(:wireguard_ipv6_network, Types.CIDR,
    default: "fd00::3:2:0/120",
    changeset: &FzHttp.Validator.validate_ip_type_inclusion(&1, &2, [:ipv6])
  )

  defconfig(:wireguard_ipv6_address, Types.IP,
    default: "fd00::3:2:1",
    changeset: &FzHttp.Validator.validate_ip_type_inclusion(&1, &2, [:ipv6])
  )

  defconfig(:wireguard_private_key_path, :string,
    default: "/var/firezone/private_key"
    # changeset: &FzHttp.Validator.validate_file(&1, &2)
  )

  ##############################################
  ## HTTP Client Settings
  ##############################################

  defconfig(:http_client_ssl_opts, :map,
    default: %{},
    changeset: fn changeset, _key ->
      %{
        changeset
        | changes: %{
            changeset.changes
            | http_client_ssl_opts: FzCommon.map_ssl_opts(changeset.changes.http_client_ssl_opts)
          }
      }
    end
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
    changeset: &FzHttp.Validator.validate_email/2
  )

  @doc """
  Method to use for sending outbound email. If not set, will default to `sendmail`.

  See the list of [Swoosh Adapters](https://github.com/swoosh/swoosh#adapters).
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
         Swoosh.Adapters.SparkPost,
         FzHttpWeb.Mailer.NoopAdapter
       ]
     )},
    default: FzHttpWeb.Mailer.NoopAdapter,
    legacy_keys: [{:env, "OUTBOUND_EMAIL_PROVIDER", "0.9"}]
  )

  defconfig(:outbound_email_adapter_opts, :map,
    default: %{},
    legacy_keys: [{:env, "OUTBOUND_EMAIL_CONFIGS", "0.9"}]
  )

  ##############################################
  ## Appearance
  ##############################################

  @doc """
  The path to a logo image file to replace default Firezone logo.
  """
  defconfig(:logo_path, :string,
    default: nil,
    changeset: fn changeset, key ->
      FzHttp.Validator.validate_file(changeset, key,
        extensions: ~w".jpg .jpeg .png .gif .webp .avif .svg .tiff"
      )
    end
  )
end
