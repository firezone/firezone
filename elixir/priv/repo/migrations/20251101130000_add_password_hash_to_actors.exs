defmodule Portal.Repo.Migrations.AddPasswordHashToActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:password_hash, :text)
    end
  end
end
