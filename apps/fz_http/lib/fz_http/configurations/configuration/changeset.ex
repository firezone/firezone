defmodule FzHttp.Configurations.Configuration.Changeset do
  use FzHttp, :changeset
  import FzHttp.Config, only: [config_changeset: 2]

  # Postgres max int size is 4 bytes
  @max_vpn_session_duration 2_147_483_647

  @fields ~w[
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
    ]a

  @spec changeset(
          {map, map}
          | %{
              :__struct__ => atom | %{:__changeset__ => map, optional(any) => any},
              optional(atom) => any
            },
          :invalid | %{optional(:__struct__) => none, optional(atom | binary) => any}
        ) :: any
  def changeset(configuration, attrs) do
    changeset =
      configuration
      |> cast(attrs, @fields)
      |> cast_embed(:logo)
      |> cast_embed(:openid_connect_providers,
        with: {FzHttp.Configurations.Configuration.OpenIDConnectProvider, :changeset, []}
      )
      |> cast_embed(:saml_identity_providers,
        with: {FzHttp.Configurations.Configuration.SAMLIdentityProvider, :changeset, []}
      )
      |> trim_change(:default_client_dns)
      |> trim_change(:default_client_endpoint)

    Enum.reduce(@fields, changeset, fn field, changeset ->
      config_changeset(changeset, field)
    end)
  end

  def max_vpn_session_duration, do: @max_vpn_session_duration
end
