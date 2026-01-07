defmodule Portal.Repo.Migrations.CreatePolicies do
  use Ecto.Migration

  def change do
    create(index(:resources, [:account_id, :id], unique: true))
    create(index(:actor_groups, [:account_id, :id], unique: true))

    create table(:policies, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)

      add(
        :actor_group_id,
        references(:actor_groups,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(
        :resource_id,
        references(:resources,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(:account_id, references(:accounts, type: :binary_id), null: false)

      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:policies, [:account_id, :name], unique: true))
    create(index(:policies, [:account_id, :resource_id, :actor_group_id], unique: true))
  end
end
