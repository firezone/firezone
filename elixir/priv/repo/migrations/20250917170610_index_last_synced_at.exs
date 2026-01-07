defmodule Portal.Repo.Migrations.IndexLastSyncedAt do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(
      index(:actors, [:last_synced_at], where: "last_synced_at IS NOT NULL", concurrently: true)
    )

    create_if_not_exists(
      index(:actor_groups, [:last_synced_at],
        where: "last_synced_at IS NOT NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:actor_group_memberships, [:last_synced_at],
        where: "last_synced_at IS NOT NULL",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:actors, [:last_synced_at],
        where: "last_synced_at IS NOT NULL",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:actor_groups, [:last_synced_at],
        where: "last_synced_at IS NOT NULL",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:actor_group_memberships, [:last_synced_at],
        where: "last_synced_at IS NOT NULL",
        concurrently: true
      )
    )
  end
end
