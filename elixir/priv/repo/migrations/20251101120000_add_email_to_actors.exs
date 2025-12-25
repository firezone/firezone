defmodule Portal.Repo.Migrations.AddEmailToActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:email, :citext)
    end

    create(
      index(:actors, [:account_id, :email],
        name: :actors_account_id_email_index,
        unique: true,
        where: "email IS NOT NULL"
      )
    )
  end
end
