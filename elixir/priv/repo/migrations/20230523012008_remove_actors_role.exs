defmodule Portal.Repo.Migrations.RemoveActorsRole do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      remove(:role)
    end
  end
end
