defmodule Portal.Repo.Migrations.RemoveGatewayGroupTags do
  use Ecto.Migration

  def change do
    alter table(:gateway_groups) do
      remove(:tags, {:array, :string}, null: false, default: [])
    end
  end
end
