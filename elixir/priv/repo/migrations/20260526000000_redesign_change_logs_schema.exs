defmodule Portal.Repo.Migrations.RedesignChangeLogsSchema do
  use Ecto.Migration

  def up do
    alter table(:change_logs) do
      add(:id, :uuid)
    end

    # Backfill ids with uuidv7 derived from inserted_at so historical rows
    # sort chronologically by id after inserted_at is dropped.
    execute("UPDATE change_logs SET id = uuidv7(inserted_at - clock_timestamp())")

    # Replication writes id explicitly from the WAL commit_timestamp; the
    # default is a safety net for any future manual inserts.
    alter table(:change_logs) do
      modify(:id, :uuid, null: false, default: fragment("uuidv7()"))
    end

    # Preserve uniqueness of lsn for replication dedupe (insert_all with
    # on_conflict: :nothing, conflict_target: [:lsn]).
    create(unique_index(:change_logs, [:lsn]))

    execute("ALTER TABLE change_logs DROP CONSTRAINT change_logs_pkey")
    execute("ALTER TABLE change_logs ADD PRIMARY KEY (id)")

    alter table(:change_logs) do
      modify(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # id encodes the time; the column (and its index) are no longer needed.
      remove(:inserted_at)
    end
  end

  def down do
    alter table(:change_logs) do
      add(:inserted_at, :utc_datetime_usec)
    end

    execute("UPDATE change_logs SET inserted_at = uuid_extract_timestamp(id)")

    alter table(:change_logs) do
      modify(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:change_logs, [:inserted_at]))

    drop(constraint(:change_logs, :change_logs_account_id_fkey))

    execute("ALTER TABLE change_logs DROP CONSTRAINT change_logs_pkey")
    execute("ALTER TABLE change_logs ADD PRIMARY KEY (lsn)")

    drop(unique_index(:change_logs, [:lsn]))

    alter table(:change_logs) do
      remove(:id)
    end
  end
end
