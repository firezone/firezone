defmodule Portal.Repo.Migrations.SetNotNullOnGroupsName do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      modify(:name, :string, null: false, from: {:string, null: true})
    end
  end
end
