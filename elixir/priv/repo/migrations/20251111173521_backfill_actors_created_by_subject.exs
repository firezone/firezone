defmodule Portal.Repo.Migrations.BackfillActorsCreatedBySubject do
  use Ecto.Migration

  def up do
    # Backfill existing actors with system created_by
    execute("""
      UPDATE actors
      SET created_by = 'system'
      WHERE created_by IS NULL
    """)

    # modify column to not null after backfill
    alter table(:actors) do
      modify(:created_by, :string, null: false)
    end
  end

  def down do
    # Modify column to allow nulls
    alter table(:actors) do
      modify(:created_by, :string, null: true)
    end

    # Remove backfilled data
    execute("""
      UPDATE actors
      SET created_by = NULL,
          created_by_subject = NULL
      WHERE created_by = 'system'
    """)
  end
end
