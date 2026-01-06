defmodule Portal.Repo.Migrations.AddActorName do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:name, :string, null: false)
    end
  end
end
