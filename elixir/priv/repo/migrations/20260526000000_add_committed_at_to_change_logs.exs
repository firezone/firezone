defmodule Portal.Repo.Migrations.AddCommittedAtToChangeLogs do
  use Ecto.Migration

  def up do
    alter table(:change_logs) do
      add(:committed_at, :utc_datetime_usec)
    end

    create(index(:change_logs, [:committed_at]))

    execute("""
    UPDATE change_logs
    SET committed_at = inserted_at
    WHERE committed_at IS NULL
    """)

    alter table(:change_logs) do
      modify(:committed_at, :utc_datetime_usec,
        null: false,
        from: {:utc_datetime_usec, null: true}
      )
    end

    drop(index(:change_logs, [:inserted_at]))
  end

  def down do
    create(index(:change_logs, [:inserted_at]))

    alter table(:change_logs) do
      remove(:committed_at)
    end
  end
end
