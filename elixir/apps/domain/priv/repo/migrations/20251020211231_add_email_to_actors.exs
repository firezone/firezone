defmodule Domain.Repo.Migrations.AddEmailToActors do
  use Domain, :migration

  def change do
    alter table(:actors) do
      add(:email, :citext)
    end

    # TODO: IDP REFACTOR
    # Add not-null constraint and update this index when all accounts have migrated
    create(index(:actors, [:account_id, :email], unique: true, where: "email IS NOT NULL"))
  end
end
