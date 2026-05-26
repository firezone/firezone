defmodule Portal.Repo.Migrations.RedesignChangeLogsSchema do
  use Ecto.Migration

  def up do
    rename(table(:change_logs), :inserted_at, to: :timestamp)
    rename(index(:change_logs, [:inserted_at], name: :change_logs_inserted_at_index), to: :change_logs_timestamp_index)

    alter table(:change_logs) do
      modify(:timestamp, :utc_datetime_usec, default: nil)
      add(:event_id, :bytea)
    end

    # 96-bit event_id = [4 bits log_type=0xC][52 bits seq_start][40 bits tenant_offset].
    # seq_start is the migration-run time in unix microseconds, shared across all
    # backfilled rows. tenant_offset is ROW_NUMBER ordered by lsn per account.
    # Post-migration consumer boots pick a later seq_start, so backfilled rows
    # sort strictly before any new rows.
    execute("""
    UPDATE change_logs c
    SET event_id =
      substring(
        int8send((12::bigint << 52) | (EXTRACT(EPOCH FROM now()) * 1000000)::bigint)
        FROM 2 FOR 7
      ) || substring(int8send(r.off) FROM 4 FOR 5)
    FROM (
      SELECT lsn, (ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY lsn) - 1)::bigint AS off
      FROM change_logs
    ) r
    WHERE c.lsn = r.lsn;
    """)

    alter table(:change_logs) do
      modify(:event_id, :bytea, null: false)

      modify(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )
    end

    create(constraint(:change_logs, :event_id_is_12_bytes, check: "octet_length(event_id) = 12"))

    execute("ALTER TABLE change_logs DROP CONSTRAINT change_logs_pkey")
    execute("ALTER TABLE change_logs ADD PRIMARY KEY (account_id, event_id)")
    create(unique_index(:change_logs, [:lsn]))
  end

  def down do
    drop(unique_index(:change_logs, [:lsn]))
    execute("ALTER TABLE change_logs DROP CONSTRAINT change_logs_pkey")
    execute("ALTER TABLE change_logs ADD PRIMARY KEY (lsn)")

    drop(constraint(:change_logs, :event_id_is_12_bytes))
    drop(constraint(:change_logs, :change_logs_account_id_fkey))

    alter table(:change_logs) do
      remove(:event_id)
    end

    rename(table(:change_logs), :timestamp, to: :inserted_at)
    rename(index(:change_logs, [:timestamp], name: :change_logs_timestamp_index), to: :change_logs_inserted_at_index)

    alter table(:change_logs) do
      modify(:inserted_at, :utc_datetime_usec, default: fragment("now()"))
    end
  end
end
