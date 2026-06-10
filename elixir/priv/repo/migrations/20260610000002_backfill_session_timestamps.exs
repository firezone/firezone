defmodule Portal.Repo.Migrations.BackfillSessionTimestamps do
  use Ecto.Migration

  # Backfills timestamp = inserted_at for session rows that predate the
  # timestamp column, then mirrors the inserted_at indexes onto timestamp so
  # the queries that switched to timestamp keep their plans. The backfill
  # runs as a temporary procedure so each batch commits on its own instead of
  # accumulating one long transaction; that and the concurrent index builds
  # both need to run outside the migration transaction. Rows written by old
  # code while the release rolls out are swept by the manual migration
  # 20260610000003_enforce_session_timestamps before timestamp becomes
  # NOT NULL.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE PROCEDURE backfill_session_timestamps(tbl regclass)
    LANGUAGE plpgsql
    AS $$
    DECLARE
      updated bigint;
      total bigint := 0;
    BEGIN
      LOOP
        EXECUTE format($q$
          WITH batch AS (
            SELECT ctid FROM %1$s WHERE "timestamp" IS NULL LIMIT 10000
          )
          UPDATE %1$s t SET "timestamp" = t.inserted_at
          FROM batch b WHERE t.ctid = b.ctid
        $q$, tbl);

        GET DIAGNOSTICS updated = ROW_COUNT;
        EXIT WHEN updated = 0;

        COMMIT;
        total := total + updated;
        RAISE NOTICE 'Backfilled % % timestamps so far', total, tbl;
      END LOOP;
    END;
    $$
    """)

    execute("CALL backfill_session_timestamps('client_sessions')")
    execute("CALL backfill_session_timestamps('gateway_sessions')")
    execute("CALL backfill_session_timestamps('portal_sessions')")
    execute("DROP PROCEDURE backfill_session_timestamps(regclass)")

    # Dropping leftovers first makes the migration re-runnable: a failed
    # CREATE INDEX CONCURRENTLY leaves an INVALID index behind that would
    # otherwise make the retry fail with "already exists".
    execute("DROP INDEX CONCURRENTLY IF EXISTS client_sessions_timestamp_index")
    create(index(:client_sessions, [:timestamp], concurrently: true))

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS client_sessions_account_id_device_id_timestamp_index"
    )

    create(
      index(:client_sessions, [:account_id, :device_id, {:desc, :timestamp}],
        concurrently: true
      )
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS gateway_sessions_timestamp_index")
    create(index(:gateway_sessions, [:timestamp], concurrently: true))

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS gateway_sessions_account_id_device_id_timestamp_index"
    )

    create(
      index(:gateway_sessions, [:account_id, :device_id, {:desc, :timestamp}],
        concurrently: true
      )
    )
  end

  def down do
    drop(index(:client_sessions, [:timestamp]))
    drop(index(:client_sessions, [:account_id, :device_id, {:desc, :timestamp}]))
    drop(index(:gateway_sessions, [:timestamp]))
    drop(index(:gateway_sessions, [:account_id, :device_id, {:desc, :timestamp}]))
  end
end
