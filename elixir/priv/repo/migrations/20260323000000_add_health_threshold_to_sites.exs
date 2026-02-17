defmodule Portal.Repo.Migrations.AddHealthThresholdToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add(:health_threshold, :integer, null: false, default: 1)
    end
  end
end
