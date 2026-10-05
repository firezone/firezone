defmodule Portal.Repo.Migrations.AddDisabledByDirectoryIdToActors do
  @moduledoc """
  Records which directory disabled an actor, so a sync re-enables only the
  actors it disabled itself and never one an admin disabled.

  The column starts out NULL everywhere, so the constraints are added NOT VALID
  and validated afterwards without blocking writes for the scan.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("ALTER TABLE actors ADD COLUMN IF NOT EXISTS disabled_by_directory_id uuid")

    execute("""
    ALTER TABLE actors
      ADD CONSTRAINT actors_disabled_by_directory_id_fkey
      FOREIGN KEY (account_id, disabled_by_directory_id)
      REFERENCES directories (account_id, id)
      ON DELETE SET NULL (disabled_by_directory_id)
      NOT VALID
    """)

    execute("""
    ALTER TABLE actors
      ADD CONSTRAINT disabled_by_directory_requires_disabled
      CHECK (disabled_by_directory_id IS NULL OR is_disabled)
      NOT VALID
    """)

    execute("ALTER TABLE actors VALIDATE CONSTRAINT actors_disabled_by_directory_id_fkey")
    execute("ALTER TABLE actors VALIDATE CONSTRAINT disabled_by_directory_requires_disabled")
  end

  def down do
    execute("ALTER TABLE actors DROP CONSTRAINT IF EXISTS disabled_by_directory_requires_disabled")
    execute("ALTER TABLE actors DROP CONSTRAINT IF EXISTS actors_disabled_by_directory_id_fkey")
    execute("ALTER TABLE actors DROP COLUMN IF EXISTS disabled_by_directory_id")
  end
end
