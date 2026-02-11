defmodule Portal.Repo.Migrations.BackfillGroupIdpIdAndValidateFk do
  @moduledoc """
  Backfills group_idp_id from existing groups and validates the FK constraint.

  This is step 2 of a 3-migration sequence. Runs outside a transaction so locks
  are released between statements:
  - UPDATE takes ROW EXCLUSIVE lock (concurrent reads allowed)
  - VALIDATE CONSTRAINT takes SHARE UPDATE EXCLUSIVE lock (concurrent reads AND writes allowed)
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # Backfill group_idp_id from existing groups
    execute("""
    UPDATE policies p
    SET group_idp_id = g.idp_id
    FROM groups g
    WHERE p.account_id = g.account_id AND p.group_id = g.id
    """)

    # Validate the NOT VALID FK constraint
    execute("ALTER TABLE policies VALIDATE CONSTRAINT policies_group_id_fkey")
  end

  def down do
    # No-op: validation and backfill don't need reversal
    # (Migration 1's down handles the structural rollback)
  end
end
