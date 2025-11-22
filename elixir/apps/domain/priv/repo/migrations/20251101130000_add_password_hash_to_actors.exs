defmodule Domain.Repo.Migrations.AddPasswordHashToActors do
  use Domain, :migration

  def change do
    alter table(:actors) do
      add(:password_hash, :text)
    end
  end
end
