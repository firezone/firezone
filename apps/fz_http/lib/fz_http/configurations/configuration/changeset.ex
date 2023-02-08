defmodule FzHttp.Configurations.Configuration.Changeset do
  use FzHttp, :changeset
  import FzHttp.Config, only: [config_changeset: 2]

  @min_mtu 576
  @max_mtu 1500
  @min_persistent_keepalive 0
  @max_persistent_keepalive 120

  # Postgres max int size is 4 bytes
  @max_pg_integer 2_147_483_647
  @min_vpn_session_duration 0
  @max_vpn_session_duration @max_pg_integer

  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, ~w[
      local_auth_enabled
      allow_unprivileged_device_management
      allow_unprivileged_device_configuration
      disable_vpn_on_oidc_error
      default_client_persistent_keepalive
      default_client_mtu
      default_client_endpoint
      default_client_dns
      default_client_allowed_ips
      vpn_session_duration
    ]a)
    |> cast_embed(:logo)
    |> cast_embed(:openid_connect_providers,
      with: {FzHttp.Configurations.Configuration.OpenIDConnectProvider, :changeset, []}
    )
    |> cast_embed(:saml_identity_providers,
      with: {FzHttp.Configurations.Configuration.SAMLIdentityProvider, :changeset, []}
    )
    |> trim_change(:default_client_dns)
    |> config_changeset(:default_client_dns)
    |> trim_change(:default_client_endpoint)
    |> config_changeset(:default_client_endpoint)
    |> validate_no_duplicates(:default_client_dns)
    |> validate_no_duplicates(:default_client_allowed_ips)
    |> validate_number(:default_client_mtu,
      greater_than_or_equal_to: @min_mtu,
      less_than_or_equal_to: @max_mtu
    )
    |> validate_number(:default_client_persistent_keepalive,
      greater_than_or_equal_to: @min_persistent_keepalive,
      less_than_or_equal_to: @max_persistent_keepalive
    )
    |> validate_number(:vpn_session_duration,
      greater_than_or_equal_to: @min_vpn_session_duration,
      less_than_or_equal_to: @max_vpn_session_duration
    )

    # |> validate_config_field(:default_client_mtu)
  end

  def max_vpn_session_duration, do: @max_vpn_session_duration
end
