defmodule Domain.Repo.Migrations.AddActorEmails do
  use Ecto.Migration

  def change do
    create(table(:actor_emails, primary_key: false)) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :actor_id, references(:actors, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create(index(:actor_emails, [:actor_id]))
    create(index(:actor_emails, [:account_id, :email], unique: true))
  end
end
