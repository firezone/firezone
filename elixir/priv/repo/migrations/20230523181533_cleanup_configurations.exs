defmodule Portal.Repo.Migrations.CleanupConfigurations do
  use Ecto.Migration

  def change do
    execute("delete from configurations")

    alter table(:configurations) do
      remove(:allow_unprivileged_device_management)
      remove(:allow_unprivileged_device_configuration)
      remove(:local_auth_enabled)
      remove(:disable_vpn_on_oidc_error)
      remove(:default_client_persistent_keepalive)
      remove(:default_client_mtu)
      remove(:default_client_endpoint)
      remove(:default_client_dns)
      remove(:default_client_allowed_ips)
      remove(:vpn_session_duration)

      add(:devices_upstream_dns, {:array, :string}, default: [])

      add(:account_id, references(:accounts, type: :binary_id), null: false)
    end

    create(index(:configurations, [:account_id], unique: true))
  end
end
