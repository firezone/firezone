defmodule Portal.Repo.Migrations.RenameActorGroupsToGroups do
  use Ecto.Migration

  def change do
    # Rename the table from actor_groups to groups
    rename(table(:actor_groups), to: table(:groups))

    # Rename the column in the policies table
    rename(table(:policies), :actor_group_id, to: :group_id)

    # Rename indexes on the groups table (previously actor_groups)
    execute(
      """
        ALTER INDEX IF EXISTS actor_groups_pkey
        RENAME TO groups_pkey;
      """,
      """
        ALTER INDEX IF EXISTS groups_pkey
        RENAME TO actor_groups_pkey;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_groups_account_id_id_index
        RENAME TO groups_account_id_id_index;
      """,
      """
        ALTER INDEX IF EXISTS groups_account_id_id_index
        RENAME TO actor_groups_account_id_id_index;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_groups_account_id_index
        RENAME TO groups_account_id_index;
      """,
      """
        ALTER INDEX IF EXISTS groups_account_id_index
        RENAME TO actor_groups_account_id_index;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_groups_account_id_name_index
        RENAME TO groups_account_id_name_index;
      """,
      """
        ALTER INDEX IF EXISTS groups_account_id_name_index
        RENAME TO actor_groups_account_id_name_index;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_groups_account_idp_fields_index
        RENAME TO groups_account_idp_fields_index;
      """,
      """
        ALTER INDEX IF EXISTS groups_account_idp_fields_index
        RENAME TO actor_groups_account_idp_fields_index;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_groups_directory_id_index
        RENAME TO groups_directory_id_index;
      """,
      """
        ALTER INDEX IF EXISTS groups_directory_id_index
        RENAME TO actor_groups_directory_id_index;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS actor_groups_last_synced_at_index
        RENAME TO groups_last_synced_at_index;
      """,
      """
        ALTER INDEX IF EXISTS groups_last_synced_at_index
        RENAME TO actor_groups_last_synced_at_index;
      """
    )

    # Rename indexes on the policies table
    execute(
      """
        ALTER INDEX IF EXISTS policies_account_id_resource_id_actor_group_id_index
        RENAME TO policies_account_id_resource_id_group_id_index;
      """,
      """
        ALTER INDEX IF EXISTS policies_account_id_resource_id_group_id_index
        RENAME TO policies_account_id_resource_id_actor_group_id_index;
      """
    )

    execute(
      """
        ALTER INDEX IF EXISTS policies_actor_group_id_index
        RENAME TO policies_group_id_index;
      """,
      """
        ALTER INDEX IF EXISTS policies_group_id_index
        RENAME TO policies_actor_group_id_index;
      """
    )

    # Rename foreign key constraints on the groups table
    execute(
      """
        ALTER TABLE groups
        RENAME CONSTRAINT actor_groups_account_id_fkey
        TO groups_account_id_fkey;
      """,
      """
        ALTER TABLE groups
        RENAME CONSTRAINT groups_account_id_fkey
        TO actor_groups_account_id_fkey;
      """
    )

    execute(
      """
        ALTER TABLE groups
        RENAME CONSTRAINT actor_groups_directory_id_fkey
        TO groups_directory_id_fkey;
      """,
      """
        ALTER TABLE groups
        RENAME CONSTRAINT groups_directory_id_fkey
        TO actor_groups_directory_id_fkey;
      """
    )

    # Rename CHECK constraint on groups table
    execute(
      """
        ALTER TABLE groups
        RENAME CONSTRAINT actor_groups_entity_type_must_be_valid
        TO groups_entity_type_must_be_valid;
      """,
      """
        ALTER TABLE groups
        RENAME CONSTRAINT groups_entity_type_must_be_valid
        TO actor_groups_entity_type_must_be_valid;
      """
    )

    # Rename foreign key constraint on policies table
    execute(
      """
        ALTER TABLE policies
        RENAME CONSTRAINT policies_actor_group_id_fkey
        TO policies_group_id_fkey;
      """,
      """
        ALTER TABLE policies
        RENAME CONSTRAINT policies_group_id_fkey
        TO policies_actor_group_id_fkey;
      """
    )

    # Update the memberships table foreign key constraint that references groups
    # (it already references the right column name but the constraint points to actor_groups)
    execute(
      """
        ALTER TABLE memberships
        DROP CONSTRAINT IF EXISTS memberships_group_id_fkey;
      """,
      """
        ALTER TABLE memberships
        ADD CONSTRAINT memberships_group_id_fkey
        FOREIGN KEY (group_id) REFERENCES actor_groups(id) ON DELETE CASCADE;
      """
    )

    execute(
      """
        ALTER TABLE memberships
        ADD CONSTRAINT memberships_group_id_fkey
        FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE;
      """,
      """
        ALTER TABLE memberships
        DROP CONSTRAINT IF EXISTS memberships_group_id_fkey;
      """
    )
  end
end
