defmodule Domain.Repo.Migrations.UpdatePolicyIndexes do
  use Ecto.Migration

  def up do
    drop(index(:policies, [:account_id, :name]))
    drop(index(:policies, [:account_id, :resource_id, :actor_group_id]))

    create(index(:policies, [:account_id, :name], unique: true, where: "deleted_at IS NULL"))

    create(
      index(:policies, [:account_id, :resource_id, :actor_group_id],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )
  end

  def down do
    drop(index(:policies, [:account_id, :name]))
    drop(index(:policies, [:account_id, :resource_id, :actor_group_id]))

    create(index(:policies, [:account_id, :name], unique: true))
    create(index(:policies, [:account_id, :resource_id, :actor_group_id], unique: true))
  end
end
