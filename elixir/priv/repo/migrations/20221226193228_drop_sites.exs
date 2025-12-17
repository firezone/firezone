defmodule Portal.Repo.Migrations.DropSites do
  use Ecto.Migration

  def change do
    drop(table(:sites))
  end
end
