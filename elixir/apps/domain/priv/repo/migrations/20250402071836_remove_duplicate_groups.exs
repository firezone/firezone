defmodule Domain.Repo.Migrations.RemoveDuplicateGroups do
  use Ecto.Migration

  def change do
    # Due to a bug we had where we mistakenly returned an empty list for
    # group API fetches, we ended up deleting all groups for a particular customer.
    # We need to clean these up and fix the index such that it won't happen again.

    # Step 1: Remove all duplicate deleted groups
    execute("""
    DELETE FROM actor_groups
    WHERE id IN (
      SELECT a.id
      FROM actor_groups a
      INNER JOIN actor_groups b
      ON a.account_id = b.account_id
      AND a.provider_id = b.provider_id
      AND a.provider_identifier = b.provider_identifier
      WHERE a.deleted_at IS NOT NULL
      AND b.deleted_at IS NULL
      AND a.provider_id IS NOT NULL
      AND a.provider_identifier IS NOT NULL
    )
    """)

    # Step 2: Drop existing index
    drop(
      index(:actor_groups, [:account_id, :provider_id, :provider_identifier],
        unique: true,
        where:
          "deleted_at IS NULL AND provider_id IS NOT NULL AND provider_identifier IS NOT NULL"
      )
    )

    # Step 3: Create new index
    create(
      index(:actor_groups, [:account_id, :provider_id, :provider_identifier],
        unique: true,
        where: "provider_id IS NOT NULL AND provider_identifier IS NOT NULL"
      )
    )
  end
end
