defmodule Portal.Repo.Migrations.CreateOsReleases do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:os_releases, primary_key: false) do
      add(:os, :string, null: false, primary_key: true)
      add(:line, :string, null: false, primary_key: true)
      add(:latest_version, :string, null: false)
      add(:supported, :boolean, null: false)
      add(:fetched_at, :timestamptz, null: false)

      timestamps()
    end
  end
end
