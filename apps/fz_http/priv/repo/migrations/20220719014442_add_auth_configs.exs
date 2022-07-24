defmodule FzHttp.Repo.Migrations.AddAuthConfigs do
  use Ecto.Migration

  def change do
    alter table("configurations") do
      add :local_auth_enabled, :boolean
      add :allow_unprivileged_device_management, :boolean
      add :openid_connect_providers, :map
      add :disable_vpn_on_oidc_error, :boolean
      add :auto_create_oidc_users, :boolean
    end
  end
end
