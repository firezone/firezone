defmodule Portal.Repo.Migrations.AddActorIdToClientSessions do
  use Ecto.Migration

  # Records which actor's client connected, so session logs are searchable by
  # actor. No FK: the column is copied into session_logs, which must survive
  # actor deletion. Existing rows are backfilled from the owning device in
  # batches; the column stays nullable because rows written by old code
  # during the rollout window have no actor recorded.
  #
  # The backfill runs as a temporary procedure so each batch commits on its
  # own instead of accumulating one long transaction, which requires running
  # outside the migration transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:client_sessions) do
      add(:actor_id, :binary_id)
    end

    execute("""
    CREATE OR REPLACE PROCEDURE backfill_client_sessions_actor_id()
    LANGUAGE plpgsql
    AS $$
    DECLARE
      updated bigint;
      total bigint := 0;
    BEGIN
      LOOP
        WITH batch AS (
          SELECT ctid FROM client_sessions WHERE actor_id IS NULL LIMIT 10000
        )
        UPDATE client_sessions cs SET actor_id = d.actor_id
        FROM batch b, devices d
        WHERE cs.ctid = b.ctid
          AND d.account_id = cs.account_id
          AND d.id = cs.device_id;

        GET DIAGNOSTICS updated = ROW_COUNT;
        EXIT WHEN updated = 0;

        COMMIT;
        total := total + updated;
        RAISE NOTICE 'Backfilled % client_sessions actor_ids so far', total;
      END LOOP;
    END;
    $$
    """)

    execute("CALL backfill_client_sessions_actor_id()")
    execute("DROP PROCEDURE backfill_client_sessions_actor_id()")
  end

  def down do
    alter table(:client_sessions) do
      remove(:actor_id, :binary_id)
    end
  end
end
