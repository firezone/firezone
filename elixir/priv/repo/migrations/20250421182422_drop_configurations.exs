defmodule Portal.Repo.Migrations.DropConfigurations do
  use Ecto.Migration

  def change do
    drop(table(:configurations))
  end
end
