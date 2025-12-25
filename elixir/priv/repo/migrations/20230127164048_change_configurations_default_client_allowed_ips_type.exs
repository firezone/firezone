defmodule Portal.Repo.Migrations.ChangeConfigurationsDefaultClientAllowedIpsType do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      modify(:default_client_allowed_ips, :text)
    end
  end
end
