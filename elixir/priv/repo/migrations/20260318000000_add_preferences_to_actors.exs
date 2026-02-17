defmodule Portal.Repo.Migrations.AddPreferencesToActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:preferences, :map)
    end
  end
end
