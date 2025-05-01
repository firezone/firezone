defmodule Domain.Repo.Migrations.AddActorResources do
  use Ecto.Migration

  def up do
    create table(:actor_resources, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:actor_id, references(:actors, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:resource_id, references(:resources, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  def down do
    drop(table(:actor_resources))
  end
end
