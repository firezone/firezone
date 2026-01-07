defmodule Portal.Repo.Migrations.DeleteGatewayGroupsRouting do
  use Ecto.Migration

  def change do
    alter table(:gateway_groups) do
      remove(:routing, :string)
    end
  end
end
