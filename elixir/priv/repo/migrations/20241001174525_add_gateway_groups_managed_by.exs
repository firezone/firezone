defmodule Portal.Repo.Migrations.AddGatewayGroupsManagedBy do
  use Ecto.Migration

  def change do
    alter table(:gateway_groups) do
      add(:managed_by, :string, null: false, default: "account")
    end
  end
end
