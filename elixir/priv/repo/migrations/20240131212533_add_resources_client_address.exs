defmodule Portal.Repo.Migrations.AddResourcesClientAddress do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      add(:address_description, :text)
    end

    execute("UPDATE resources SET address_description = address")

    execute("ALTER TABLE resources ALTER COLUMN address_description SET NOT NULL")
  end
end
