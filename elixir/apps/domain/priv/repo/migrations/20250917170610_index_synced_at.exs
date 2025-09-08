defmodule Domain.Repo.Migrations.IndexSyncedAt do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(
      index(:auth_identities, [:synced_at], where: "synced_at IS NOT NULL", concurrently: true)
    )

    create_if_not_exists(
      index(:actor_groups, [:synced_at], where: "synced_at IS NOT NULL", concurrently: true)
    )

    create_if_not_exists(
      index(:actor_group_memberships, [:synced_at],
        where: "synced_at IS NOT NULL",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:auth_identities, [:synced_at], where: "synced_at IS NOT NULL", concurrently: true)
    )

    drop_if_exists(
      index(:actor_groups, [:synced_at], where: "synced_at IS NOT NULL", concurrently: true)
    )

    drop_if_exists(
      index(:actor_group_memberships, [:synced_at],
        where: "synced_at IS NOT NULL",
        concurrently: true
      )
    )
  end
end
