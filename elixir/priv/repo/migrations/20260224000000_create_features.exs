defmodule Portal.Repo.Migrations.CreateFeatures do
  use Ecto.Migration

  def change do
    create table(:features, primary_key: false) do
      add(:feature, :string, null: false)
      add(:enabled, :boolean, null: false, default: false)
    end

    create(unique_index(:features, [:feature]))

    execute(
      "INSERT INTO features (feature, enabled) VALUES ('client_to_client', false)",
      "DELETE FROM features"
    )
  end
end
