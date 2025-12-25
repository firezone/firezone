defmodule Portal.Repo.Migrations.AddRoutingToGatewayGroup do
  use Ecto.Migration

  def change do
    alter table(:gateway_groups) do
      add(:routing, :string)
    end

    execute("UPDATE gateway_groups SET routing = 'managed'")

    execute("ALTER TABLE gateway_groups ALTER COLUMN routing SET NOT NULL")
  end
end
