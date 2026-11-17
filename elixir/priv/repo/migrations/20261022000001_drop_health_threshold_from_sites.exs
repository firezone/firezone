defmodule Portal.Repo.Migrations.DropHealthThresholdFromSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      remove(:health_threshold, :integer, null: false, default: 1)
    end
  end
end
