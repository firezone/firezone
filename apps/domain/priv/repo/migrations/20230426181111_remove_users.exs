defmodule Domain.Repo.Migrations.RemoveUsers do
  use Ecto.Migration

  def change do
    ## API tokens

    alter table(:api_tokens) do
      remove(:user_id, references(:users, type: :binary_id), null: false)
      add(:actor_id, references(:actors, type: :binary_id), null: false)
    end

    create(index(:api_tokens, [:actor_id]))

    ## Clients

    alter table(:clients) do
      remove(:user_id, references(:users, type: :binary_id), null: false)
      add(:actor_id, references(:actors, type: :binary_id), null: false)
    end

    create(
      index(:clients, [:account_id, :actor_id, :external_id],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )

    create(
      index(:clients, [:account_id, :actor_id, :name],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )

    create(
      index(:clients, [:account_id, :actor_id, :public_key],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )

    drop(table(:users))
  end
end
