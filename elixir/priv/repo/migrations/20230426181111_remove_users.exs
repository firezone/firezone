defmodule Portal.Repo.Migrations.RemoveUsers do
  use Ecto.Migration

  def change do
    ## API tokens

    alter table(:api_tokens) do
      remove(:user_id, references(:users, type: :binary_id), null: false)
      add(:actor_id, references(:actors, type: :binary_id), null: false)
    end

    create(index(:api_tokens, [:actor_id]))

    ## Devices

    alter table(:devices) do
      remove(:user_id, references(:users, type: :binary_id), null: false)
      add(:actor_id, references(:actors, type: :binary_id), null: false)
      add(:identity_id, references(:auth_identities, type: :binary_id), null: false)
    end

    create(
      index(:devices, [:account_id, :actor_id, :external_id],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )

    create(
      index(:devices, [:account_id, :actor_id, :name],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )

    create(
      index(:devices, [:account_id, :actor_id, :public_key],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )

    drop(table(:users))
  end
end
