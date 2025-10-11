defmodule Domain.Repo.Migrations.AddEmailToActors do
  use Domain, :migration

  def change do
    alter table(:actors) do
      add(:email, :citext)
    end

    create(index(:actors, [:account_id, :email], unique: true, where: "deleted_at IS NULL"))
  end
end
