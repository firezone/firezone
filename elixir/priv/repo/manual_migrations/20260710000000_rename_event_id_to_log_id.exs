defmodule Portal.Repo.Migrations.RenameEventIdToLogId do
  use Ecto.Migration

  @moduledoc """
  Renames event_id to log_id on all four log streams. All statements are
  catalog-only; the flow_logs column rename recurses to its partitions, and
  the DO block sweeps the auto-named per-partition indexes.
  """

  def up do
    execute("ALTER TABLE change_logs RENAME COLUMN event_id TO log_id")
    execute("ALTER TABLE change_logs RENAME CONSTRAINT event_id_is_12_bytes TO log_id_is_12_bytes")

    execute("ALTER TABLE session_logs RENAME COLUMN event_id TO log_id")

    execute(
      "ALTER TABLE session_logs RENAME CONSTRAINT event_id_is_12_bytes TO log_id_is_12_bytes"
    )

    execute("ALTER TABLE api_request_logs RENAME COLUMN event_id TO log_id")

    execute(
      "ALTER TABLE api_request_logs RENAME CONSTRAINT event_id_is_12_bytes TO log_id_is_12_bytes"
    )

    execute("ALTER TABLE flow_logs RENAME COLUMN event_id TO log_id")

    execute(
      "ALTER TABLE flow_logs RENAME CONSTRAINT flow_logs_event_id_must_be_12_bytes " <>
        "TO flow_logs_log_id_must_be_12_bytes"
    )

    execute("""
    DO $$
    DECLARE r record;
    BEGIN
      FOR r IN
        SELECT schemaname, indexname FROM pg_indexes
        WHERE indexname LIKE '%event\\_id%' ESCAPE '\\'
          AND tablename LIKE 'flow\\_logs%' ESCAPE '\\'
      LOOP
        EXECUTE format(
          'ALTER INDEX %I.%I RENAME TO %I',
          r.schemaname, r.indexname, replace(r.indexname, 'event_id', 'log_id')
        );
      END LOOP;
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$
    DECLARE r record;
    BEGIN
      FOR r IN
        SELECT schemaname, indexname FROM pg_indexes
        WHERE indexname LIKE '%log\\_id%' ESCAPE '\\'
          AND tablename LIKE 'flow\\_logs%' ESCAPE '\\'
      LOOP
        EXECUTE format(
          'ALTER INDEX %I.%I RENAME TO %I',
          r.schemaname, r.indexname, replace(r.indexname, 'log_id', 'event_id')
        );
      END LOOP;
    END $$;
    """)

    execute(
      "ALTER TABLE flow_logs RENAME CONSTRAINT flow_logs_log_id_must_be_12_bytes " <>
        "TO flow_logs_event_id_must_be_12_bytes"
    )

    execute("ALTER TABLE flow_logs RENAME COLUMN log_id TO event_id")

    execute(
      "ALTER TABLE api_request_logs RENAME CONSTRAINT log_id_is_12_bytes TO event_id_is_12_bytes"
    )

    execute("ALTER TABLE api_request_logs RENAME COLUMN log_id TO event_id")

    execute(
      "ALTER TABLE session_logs RENAME CONSTRAINT log_id_is_12_bytes TO event_id_is_12_bytes"
    )

    execute("ALTER TABLE session_logs RENAME COLUMN log_id TO event_id")

    execute("ALTER TABLE change_logs RENAME CONSTRAINT log_id_is_12_bytes TO event_id_is_12_bytes")
    execute("ALTER TABLE change_logs RENAME COLUMN log_id TO event_id")
  end
end
