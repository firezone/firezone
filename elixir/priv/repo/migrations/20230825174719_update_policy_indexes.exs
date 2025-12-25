defmodule Portal.Repo.Migrations.UpdatePolicyIndexes do
  use Ecto.Migration

  def change do
    drop(index(:policies, [:account_id, :name], unique: true))
    drop(index(:policies, [:account_id, :resource_id, :actor_group_id], unique: true))

    create(index(:policies, [:account_id, :name], unique: true, where: "deleted_at IS NULL"))

    create(
      index(:policies, [:account_id, :resource_id, :actor_group_id],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )
  end
end
