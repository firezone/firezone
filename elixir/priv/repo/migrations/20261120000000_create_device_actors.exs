defmodule Portal.Repo.Migrations.CreateDeviceActors do
  use Ecto.Migration

  def change do
    create table(:device_actors, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :device_id,
        references(:devices,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(
        :actor_id,
        references(:actors,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(:first_seen_at, :timestamptz, null: false)
      add(:last_seen_at, :timestamptz, null: false)
    end

    create(index(:device_actors, [:account_id, :actor_id]))
  end
end
