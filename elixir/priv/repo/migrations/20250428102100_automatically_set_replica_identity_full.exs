defmodule Portal.Repo.Migrations.AutomaticallySetReplicaIdentityFull do
  use Ecto.Migration

  # Creates a trigger that automatically sets the REPLICA IDENTITY to FULL for new tables. This is
  # needed to ensure we can capture changes to a table in replication in order to reliably
  # broadcast events.
  def change do
    execute(
      """
      CREATE OR REPLACE FUNCTION set_replica_identity_full()
      RETURNS EVENT_TRIGGER AS $$
      DECLARE
        rec RECORD;
      BEGIN
        FOR rec IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE command_tag = 'CREATE TABLE'
        LOOP
          EXECUTE format('ALTER TABLE %s REPLICA IDENTITY FULL', rec.object_identity);
        END LOOP;
      END;
      $$ LANGUAGE plpgsql;
      """,
      """
      DROP FUNCTION IF EXISTS set_replica_identity_full();
      """
    )

    execute(
      """
      CREATE EVENT TRIGGER trigger_set_replica_identity
      ON ddl_command_end
      WHEN TAG IN ('CREATE TABLE')
      EXECUTE FUNCTION set_replica_identity_full();
      """,
      """
      DROP EVENT TRIGGER IF EXISTS trigger_set_replica_identity;
      """
    )
  end
end
