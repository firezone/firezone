defmodule Domain.Repo.Migrations.AddResourcesClientAddress do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      add(:client_address, :string)
    end

    execute("UPDATE resources SET client_address = address")

    execute("ALTER TABLE resources ALTER COLUMN client_address SET NOT NULL")
  end
end
