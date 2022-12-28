defmodule FzHttp.Repo.Migrations.MoveCacheFallbacksToConfigurations do
  use Ecto.Migration

  alias FzCommon.FzString

  def change do
    local_auth_enabled = FzString.to_boolean(System.get_env("LOCAL_AUTH_ENABLED", "true"))

    disable_vpn_on_oidc_error =
      FzString.to_boolean(System.get_env("DISABLE_VPN_ON_OIDC_ERROR", "false"))

    allow_unprivileged_device_management =
      FzString.to_boolean(System.get_env("ALLOW_UNPRIVILEGED_DEVICE_MANAGEMENT", "true"))

    allow_unprivileged_device_configuration =
      FzString.to_boolean(System.get_env("ALLOW_UNPRIVILEGED_DEVICE_CONFIGURATION", "true"))

    execute("""
      UPDATE configurations
      SET local_auth_enabled = '#{local_auth_enabled}' WHERE configurations.local_auth_enabled IS NULL
    """)

    execute("""
      UPDATE configurations
      SET disable_vpn_on_oidc_error = '#{disable_vpn_on_oidc_error}' WHERE configurations.disable_vpn_on_oidc_error IS NULL
    """)

    execute("""
      UPDATE configurations
      SET allow_unprivileged_device_management = '#{allow_unprivileged_device_management}' WHERE configurations.allow_unprivileged_device_management IS NULL
    """)

    execute("""
      UPDATE configurations
      SET allow_unprivileged_device_configuration = '#{allow_unprivileged_device_configuration}' WHERE configurations.allow_unprivileged_device_configuration IS NULL
    """)

    # Set defaults for providers
    execute("""
      UPDATE configurations
      SET openid_connect_providers = '{}'::json
      WHERE openid_connect_providers IS NULL
    """)

    execute("""
      UPDATE configurations
      SET saml_identity_providers = '{}'::json
      WHERE saml_identity_providers IS NULL
    """)

    alter table(:configurations) do
      modify(:openid_connect_providers, :map, default: %{}, null: false)
      modify(:saml_identity_providers, :map, default: %{}, null: false)
    end
  end
end
