defmodule Portal.Repo.Migrations.UpdatePoliciesIndexesForNullableGroupId do
  @moduledoc """
  Replaces the unique index on policies to handle nullable group_id,
  and adds a reconnection lookup index on group_idp_id.

  This is step 3 of a 3-migration sequence. Runs outside a transaction
  so indexes can be created CONCURRENTLY (no write blocking).

  The partial index is created with a temporary name first, then the old index
  is dropped and the new one renamed. This avoids any window without uniqueness
  enforcement.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # Create new partial unique index concurrently with temp name (no write blocking)
    # Old index still enforces uniqueness during the build
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS
      policies_account_id_resource_id_group_id_partial_index
      ON policies (account_id, resource_id, group_id)
      WHERE group_id IS NOT NULL
    """)

    # Drop old full unique index
    drop_if_exists(
      index(:policies, [:account_id, :resource_id, :group_id],
        name: :policies_account_id_resource_id_group_id_index
      )
    )

    # Rename to the canonical name so application code doesn't need to change
    execute("""
    ALTER INDEX policies_account_id_resource_id_group_id_partial_index
    RENAME TO policies_account_id_resource_id_group_id_index
    """)

    # Create reconnection lookup index concurrently
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS
      policies_account_id_group_idp_id_index
      ON policies (account_id, group_idp_id)
      WHERE group_idp_id IS NOT NULL
    """)
  end

  def down do
    drop_if_exists(
      index(:policies, [:account_id, :group_idp_id],
        name: :policies_account_id_group_idp_id_index
      )
    )

    drop_if_exists(
      index(:policies, [:account_id, :resource_id, :group_id],
        name: :policies_account_id_resource_id_group_id_index
      )
    )

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS
      policies_account_id_resource_id_group_id_index
      ON policies (account_id, resource_id, group_id)
    """)
  end
end
