defmodule Domain.Repo.Migrations.AddEmailToActors do
  use Domain, :migration

  def change do
    alter table(:actors) do
      add(:email, :citext)
    end

    # TODO: IDP REFACTOR
    # Add check constraint to ensure email is not null if type in ('account_user', 'account_admin_user')
    create(index(:actors, [:account_id, :email], unique: true, where: "email IS NOT NULL"))
  end
end
