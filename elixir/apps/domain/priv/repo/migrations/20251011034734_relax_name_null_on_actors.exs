defmodule Domain.Repo.Migrations.RelaxNameNullOnActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      modify(:name, :string, null: true, from: {:string, null: false})
    end
  end
end
