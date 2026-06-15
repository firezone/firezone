defmodule Portal.Repo.Migrations.MoveSessionLogsFromChangeLogs do
  @moduledoc """
  Moves historic session entries (client_sessions, gateway_sessions,
  portal_sessions) from change_logs into session_logs.

  Session logs record session creation only, so insert entries are converted
  by lifting the auth context fields out of the `after` payload into columns;
  update and delete entries are removed from change_logs without being moved.

  Run this only after the release that adds the SessionLogs replication
  consumer is fully rolled out and the change_logs consumer lag is back to
  normal: historic WAL retained in the change_logs slot can still deliver
  session writes into change_logs for a while after the publication change,
  and running the move too early strands them there.

  This migration runs DML only, so there is no DDL to protect with a
  transaction. The move runs as a temporary procedure that commits after
  each batch instead of accumulating the whole move into one potentially
  hours-long transaction (which would pin the xmin horizon, block vacuum,
  and lose all progress on a crash); committing inside the procedure
  requires @disable_ddl_transaction. Each batch is a single atomic
  statement, so the migration can be safely re-run after a crash and
  resumes where it left off. Rows the SessionLogs consumer already captured
  during the deploy overlap window are deduplicated by the unique lsn (same
  WAL write = same lsn across slots). A concurrent account deletion can abort
  one batch atomically (deadlock or FK violation); just re-run.

  The move is intentionally one-way; down/0 is a no-op.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # The event_id high nibble is rewritten from 0xC (change_log) to 0x5
    # (session_log); the remaining 92 bits are preserved, so the transform is
    # injective and PK-safe.
    #
    # The loop advances on the batch count rather than the moved count: the
    # DeleteOldChangeLogs retention job can concurrently delete rows the batch
    # selected, making moved < batch while matching rows still remain.
    execute("""
    CREATE OR REPLACE PROCEDURE move_session_logs_from_change_logs()
    LANGUAGE plpgsql
    AS $$
    DECLARE
      cursor_lsn bigint := 0;
      batch_count bigint;
      batch_max_lsn bigint;
      total bigint := 0;
    BEGIN
      LOOP
        WITH batch AS (
          SELECT lsn FROM change_logs
          WHERE object IN ('client_sessions', 'gateway_sessions', 'portal_sessions')
            AND lsn > cursor_lsn
          ORDER BY lsn
          LIMIT 5000
        ),
        moved AS (
          DELETE FROM change_logs cl
          USING batch b
          WHERE cl.lsn = b.lsn
          RETURNING cl.account_id, cl.event_id, cl."timestamp", cl.lsn, cl.object,
                    cl.operation, cl."after"
        ),
        inserted AS (
          INSERT INTO session_logs
            (account_id, event_id, "timestamp", lsn, context, actor_id, actor_email,
             device_id, token_id, auth_provider_id, user_agent, remote_ip,
             remote_ip_location_region, remote_ip_location_city,
             remote_ip_location_lat, remote_ip_location_lon)
          SELECT m.account_id,
                 set_byte(m.event_id, 0, (get_byte(m.event_id, 0) & 15) | 80),
                 COALESCE((m."after" ->> 'timestamp')::timestamptz, m."timestamp"),
                 m.lsn,
                 CASE m.object
                   WHEN 'client_sessions' THEN 'client'
                   WHEN 'gateway_sessions' THEN 'gateway'
                   ELSE 'portal'
                 END,
                 -- Client session rows written before the actor_id column was
                 -- added have none in the payload; recover it from the owning
                 -- device when that device still exists.
                 COALESCE((m."after" ->> 'actor_id')::uuid, d.actor_id),
                 m."after" ->> 'actor_email',
                 (m."after" ->> 'device_id')::uuid,
                 COALESCE(m."after" ->> 'client_token_id', m."after" ->> 'gateway_token_id')::uuid,
                 (m."after" ->> 'auth_provider_id')::uuid,
                 m."after" ->> 'user_agent',
                 (m."after" ->> 'remote_ip')::inet,
                 m."after" ->> 'remote_ip_location_region',
                 m."after" ->> 'remote_ip_location_city',
                 (m."after" ->> 'remote_ip_location_lat')::float8,
                 (m."after" ->> 'remote_ip_location_lon')::float8
          FROM moved m
          LEFT JOIN devices d
            ON m.object = 'client_sessions'
            AND d.account_id = m.account_id
            AND d.id = (m."after" ->> 'device_id')::uuid
          WHERE m.operation = 'insert'
          ON CONFLICT (lsn) DO NOTHING
          RETURNING lsn
        )
        SELECT (SELECT count(*) FROM batch), (SELECT max(lsn) FROM batch)
        INTO batch_count, batch_max_lsn;

        EXIT WHEN batch_count = 0;

        COMMIT;
        cursor_lsn := batch_max_lsn;
        total := total + batch_count;
        RAISE NOTICE 'Processed % session change_logs so far', total;
      END LOOP;
    END;
    $$
    """)

    execute("CALL move_session_logs_from_change_logs()")
    execute("DROP PROCEDURE move_session_logs_from_change_logs()")
  end

  def down, do: :ok
end
