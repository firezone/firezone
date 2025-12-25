defmodule Portal.Repo.Migrations.RemoveRules do
  use Ecto.Migration

  def change do
    drop(table(:rules))
  end
end
