defmodule Domain.Repo.Migrations.BackfillActorsCreatedBySubject do
  use Ecto.Migration

  def up do
    # Backfill existing actors with system created_by
    execute("""
      UPDATE actors
      SET created_by = 'system',
          created_by_subject = jsonb_build_object('name', 'System', 'email', NULL)
      WHERE created_by IS NULL
    """)
  end

  def down do
    # Remove backfilled data
    execute("""
      UPDATE actors
      SET created_by = NULL,
          created_by_subject = NULL
      WHERE created_by = 'system'
    """)
  end
end
