defmodule Portal.Repo.Migrations.AddCommittedAtToChangeLogs do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    alter table(:change_logs) do
      add_if_not_exists(:committed_at, :utc_datetime_usec)
    end

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

    create_if_not_exists(index(:change_logs, [:committed_at], concurrently: true))

    drop_if_exists(index(:change_logs, [:inserted_at], concurrently: true))
  end

  def down do
    create_if_not_exists(index(:change_logs, [:inserted_at], concurrently: true))

    alter table(:change_logs) do
      remove_if_exists(:committed_at)
    end
  end
end
