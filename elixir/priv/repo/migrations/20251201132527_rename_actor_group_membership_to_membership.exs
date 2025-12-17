defmodule Portal.Repo.Migrations.RenameActorGroupMembershipToMembership do
  use Ecto.Migration

  def change do
    # Rename the table from actor_group_memberships to memberships
    rename(table(:actor_group_memberships), to: table(:memberships))

    # Rename the column in the flows table
    rename(table(:flows), :actor_group_membership_id, to: :membership_id)

    # Rename indexes on the flows table
    execute(
      """
        ALTER INDEX IF EXISTS flows_actor_group_membership_id_idx
        RENAME TO flows_membership_id_idx;
      """,
      """
        ALTER INDEX IF EXISTS flows_membership_id_idx
        RENAME TO flows_actor_group_membership_id_idx;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS flows_actor_group_membership_id_index
        RENAME TO flows_membership_id_index;
      """,
      """
        ALTER INDEX IF EXISTS flows_membership_id_index
        RENAME TO flows_actor_group_membership_id_index;
      """
    )

    # Rename the foreign key constraint on flows table
    execute(
      """
        ALTER TABLE flows
        RENAME CONSTRAINT flows_actor_group_membership_id_fkey
        TO flows_membership_id_fkey;
      """,
      """
        ALTER TABLE flows
        RENAME CONSTRAINT flows_membership_id_fkey
        TO flows_actor_group_membership_id_fkey;
      """
    )

    # Rename indexes on the memberships table (previously actor_group_memberships)
    execute(
      """
        ALTER INDEX IF EXISTS actor_group_memberships_pkey
        RENAME TO memberships_pkey;
      """,
      """
        ALTER INDEX IF EXISTS memberships_pkey
        RENAME TO actor_group_memberships_pkey;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_group_memberships_account_id_group_id_actor_id_index
        RENAME TO memberships_account_id_group_id_actor_id_index;
      """,
      """
        ALTER INDEX IF EXISTS memberships_account_id_group_id_actor_id_index
        RENAME TO actor_group_memberships_account_id_group_id_actor_id_index;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_group_memberships_actor_id_group_id_index
        RENAME TO memberships_actor_id_group_id_index;
      """,
      """
        ALTER INDEX IF EXISTS memberships_actor_id_group_id_index
        RENAME TO actor_group_memberships_actor_id_group_id_index;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_group_memberships_group_id_index
        RENAME TO memberships_group_id_index;
      """,
      """
        ALTER INDEX IF EXISTS memberships_group_id_index
        RENAME TO actor_group_memberships_group_id_index;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_group_memberships_last_synced_at_index
        RENAME TO memberships_last_synced_at_index;
      """,
      """
        ALTER INDEX IF EXISTS memberships_last_synced_at_index
        RENAME TO actor_group_memberships_last_synced_at_index;
      """
    )

    # Rename foreign key constraints on the memberships table
    execute(
      """
        ALTER TABLE memberships
        RENAME CONSTRAINT actor_group_memberships_account_id_fkey
        TO memberships_account_id_fkey;
      """,
      """
        ALTER TABLE memberships
        RENAME CONSTRAINT memberships_account_id_fkey
        TO actor_group_memberships_account_id_fkey;
      """
    )

    execute(
      """
        ALTER TABLE memberships
        RENAME CONSTRAINT actor_group_memberships_actor_id_fkey
        TO memberships_actor_id_fkey;
      """,
      """
        ALTER TABLE memberships
        RENAME CONSTRAINT memberships_actor_id_fkey
        TO actor_group_memberships_actor_id_fkey;
      """
    )

    execute(
      """
        ALTER TABLE memberships
        RENAME CONSTRAINT actor_group_memberships_group_id_fkey
        TO memberships_group_id_fkey;
      """,
      """
        ALTER TABLE memberships
        RENAME CONSTRAINT memberships_group_id_fkey
        TO actor_group_memberships_group_id_fkey;
      """
    )
  end
end
