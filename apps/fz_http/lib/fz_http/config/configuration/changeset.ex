defmodule FzHttp.Config.Configuration.Changeset do
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
        with: {FzHttp.Config.Configuration.OpenIDConnectProvider, :changeset, []}
      )
      |> cast_embed(:saml_identity_providers,
        with: {FzHttp.Config.Configuration.SAMLIdentityProvider, :changeset, []}
      )
      |> trim_change(:default_client_dns)
      |> trim_change(:default_client_endpoint)

    Enum.reduce(@fields, changeset, fn field, changeset ->
      config_changeset(changeset, field)
    end)
    |> ensure_no_overridden_changes()
  end

  defp ensure_no_overridden_changes(changeset) do
    changed_keys = Map.keys(changeset.changes)
    configs = FzHttp.Config.fetch_source_and_configs!(changed_keys)

    Enum.reduce(changed_keys, changeset, fn key, changeset ->
      case Map.fetch!(configs, key) do
        {{:env, source_key}, _value} ->
          add_error(
            changeset,
            key,
            "can not be changed in UI, " <>
              "it is overridden by #{source_key} environment variable"
          )

        _other ->
          changeset
      end
    end)
  end

  def max_vpn_session_duration, do: @max_vpn_session_duration
end
