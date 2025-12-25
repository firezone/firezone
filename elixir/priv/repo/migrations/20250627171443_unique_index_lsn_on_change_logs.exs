defmodule Portal.Repo.Migrations.UniqueIndexLsnOnChangeLogs do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM change_logs
    WHERE (lsn, inserted_at) NOT IN (
        SELECT lsn, MIN(inserted_at)
        FROM change_logs
        GROUP BY lsn
    )
    """)

    create(index(:change_logs, :lsn, unique: true))
  end

  def down do
    drop(index(:change_logs, :lsn, unique: true))
  end
end
