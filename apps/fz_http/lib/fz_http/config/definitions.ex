defmodule FzHttp.Config.Definitions do
  use FzHttp.Config.Definition
  alias FzHttp.Configurations
  alias FzHttp.Types
  alias FzHttp.Config.{Resolver, Caster, Validator}

  # @doc_sections [
  #   {"WebServer", [:external_url]},
  #   {"Admin Setup",
  #    "Options responsible for initial admin provisioning and resetting the admin password.",
  #    [:default_admin_email, :default_admin_password]},
  #   {"Secrets", []}
  # ]

  # TODO:
  # WIREGUARD_IPV4_NETWORK
  # WIREGUARD_IPV4_ADDRESS
  # WIREGUARD_IPV6_NETWORK
  # WIREGUARD_IPV6_ADDRESS
  # SECURE_COOKIES
  # OUTBOUND_EMAIL_FROM
  # OUTBOUND_EMAIL_PROVIDER
  # OUTBOUND_EMAIL_ADAPTER # new
  # OUTBOUND_EMAIL_ADAPTER_OPTS # new
  # MAX_DEVICES_PER_USER
  # CONNECTIVITY_CHECKS_ENABLED
  # CONNECTIVITY_CHECKS_INTERVAL
  # TELEMETRY_ENABLED
  # WIREGUARD_PRIVATE_KEY_PATH
  # SAML_ENTITY_ID
  # SAML_KEYFILE_PATH
  # SAML_CERTFILE_PATH
  # HTTP_CLIENT_SSL_OPTS
  # PHOENIX_LISTEN_ADDRESS
  # PHOENIX_PORT
  # EXTERNAL_TRUSTED_PROXIES
  # PRIVATE_CLIENTS
  # WIREGUARD_PORT
  # EGRESS_INTERFACE
  # WIREGUARD_IPV4_ENABLED
  # WIREGUARD_IPV6_ENABLED
  # WIREGUARD_IPV4_MASQUERADE
  # WIREGUARD_IPV6_MASQUERADE
  # {"logo"},
  # {"openid_connect_providers"},
  # {"saml_identity_providers"}

  # Maybe
  # DATABASE_NAME
  # DATABASE_USER
  # DATABASE_HOST
  # DATABASE_PORT
  # DATABASE_POOL
  # DATABASE_SSL
  # DATABASE_SSL_OPTS
  # DATABASE_PARAMETERS
  # DATABASE_PASSWORD

  # TODO: everything that doesn't have default is required

  @doc """
  The external URL the web UI will be accessible at.

  Must be a valid and public FQDN for ACME SSL issuance to function.

  You can add a path suffix if you want to serve firezone from a non-root path,
  eg: `https://firezone.mycorp.com/vpn`.
  """
  defconfig(:external_url, :string,
    required: true,
    changeset: &FzHttp.Validator.validate_uri/2
  )

  @doc """
  Primary administrator email.
  """
  defconfig(:default_admin_email, :string,
    required: false,
    legacy_keys: [{:env, "ADMIN_EMAIL", "0.9"}],
    changeset: &FzHttp.Validator.validate_email/2
  )

  @doc """
  Default password that will be used for creating or resetting the primary administrator account.
  """
  defconfig(:default_admin_password, :string,
    required: false,
    changeset: fn changeset, key ->
      Ecto.Changeset.validate_length(changeset, key, min: 5)
    end
  )

  @doc """
  Secret key used for signing JWTs.
  """
  defconfig(:guardian_secret_key, :string,
    required: true,
    changeset: &FzHttp.Validator.validate_base64/2
  )

  @doc """
  Secret key used for encrypting sensitive data in the database.
  """
  defconfig(:database_encryption_key, :string,
    required: true,
    changeset: &FzHttp.Validator.validate_base64/2
  )

  @doc """
  Primary secret key base for the Phoenix application.
  """
  defconfig(:secret_key_base, :string,
    required: true,
    changeset: &FzHttp.Validator.validate_base64/2
  )

  @doc """
  Signing salt for Phoenix LiveView connection tokens.
  """
  defconfig(:live_view_signing_salt, :string,
    required: true,
    changeset: &FzHttp.Validator.validate_base64/2
  )

  @doc """
  Encryption salt for cookies issued by the Phoenix web application.
  """
  defconfig(:cookie_signing_salt, :string,
    required: true,
    changeset: &FzHttp.Validator.validate_base64/2
  )

  @doc """
  Signing salt for cookies issued by the Phoenix web application.
  """
  defconfig(:cookie_encryption_salt, :string,
    required: true,
    changeset: &FzHttp.Validator.validate_base64/2
  )

  @doc false
  defconfig(:telemetry_id, :string,
    default: "unknown",
    legacy_keys: [{:env, "TID", nil}]
  )

  @doc """
  Enable or disable management of devices on unprivileged accounts.
  """
  defconfig(:allow_unprivileged_device_management, :boolean, default: true)

  @doc """
  Enable or disable configuration of device network settings for unprivileged users.
  """
  defconfig(:allow_unprivileged_device_configuration, :boolean, default: true)

  @doc """
  Enable or disable the local authentication method for all users.
  """
  defconfig(:local_auth_enabled, :boolean, default: true)

  @doc """
  Enable or disable auto disabling VPN connection on OIDC refresh error.
  """
  defconfig(:disable_vpn_on_oidc_error, :boolean, default: false)

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

  def build_config do
    db_configurations = Configurations.get_configuration!()
    env_configurations = System.get_env()

    configs()
    |> Enum.map(&build_config_item(&1, env_configurations, db_configurations))
  end

  defp build_config_item(key, env_configurations, db_configurations) do
    {type, opts} = apply(__MODULE__, key, [])

    {resolve_opts, opts} = Keyword.split(opts, [:legacy_keys, :default, :required])
    {validate_opts, opts} = Keyword.split(opts, [:changeset])

    if opts != [] do
      raise ArgumentError, "unknown options #{inspect(opts)} for configuration #{inspect(key)}"
    end

    {source, value} =
      Resolver.resolve_value!(key, env_configurations, db_configurations, resolve_opts)

    value = Caster.cast(value, type)

    {key, source, Validator.validate(key, value, type, validate_opts)}
  end
end
