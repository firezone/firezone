defmodule Portal.Repo.Migrations.AddGroupIdpIdToPolicies do
  @moduledoc """
  Adds group_idp_id column to policies and makes group_id nullable with ON DELETE SET NULL.

  This is step 1 of a 3-migration sequence. All operations here are instant catalog-only
  changes, so the ACCESS EXCLUSIVE lock is held very briefly.

  The FK constraint is added as NOT VALID to skip the validation scan — Migration 2
  will validate it outside a transaction.
  """
  use Ecto.Migration

  def up do
    # Add group_idp_id column — instant catalog change
    alter table(:policies) do
      add(:group_idp_id, :text)
    end

    # Drop existing FK constraint — instant
    execute("ALTER TABLE policies DROP CONSTRAINT policies_group_id_fkey")

    # Make group_id nullable — instant catalog change
    alter table(:policies) do
      modify(:group_id, :binary_id, null: true)
    end

    # Re-add FK with ON DELETE SET NULL, NOT VALID skips validation scan
    execute("""
    ALTER TABLE policies ADD CONSTRAINT policies_group_id_fkey
    FOREIGN KEY (account_id, group_id) REFERENCES groups(account_id, id)
    ON DELETE SET NULL (group_id)
    NOT VALID
    """)
  end

  def down do
    execute("ALTER TABLE policies DROP CONSTRAINT policies_group_id_fkey")
    execute("DELETE FROM policies WHERE group_id IS NULL")

    alter table(:policies) do
      modify(:group_id, :binary_id, null: false)
    end

    execute("""
    ALTER TABLE policies ADD CONSTRAINT policies_group_id_fkey
    FOREIGN KEY (account_id, group_id) REFERENCES groups(account_id, id)
    ON DELETE CASCADE
    """)

    alter table(:policies) do
      remove(:group_idp_id)
    end
  end
end
