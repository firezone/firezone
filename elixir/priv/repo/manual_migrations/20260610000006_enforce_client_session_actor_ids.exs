defmodule Portal.Repo.Migrations.EnforceClientSessionActorIds do
  @moduledoc """
  Makes client_sessions.actor_id NOT NULL.

  Run this only after the release that writes actor_id on every client
  session insert is fully rolled out: pods from the previous release insert
  session rows without it. The first step sweeps any rows those pods wrote
  after the deploy-time backfill ran, filling actor_id from the owning
  device. The sweep is complete: device deletion cascades to
  client_sessions, so every surviving row has a device, and client-type
  devices are constraint-checked to carry an actor_id.

  NOT NULL is applied via a NOT VALID check constraint that is validated
  separately: VALIDATE only takes a SHARE UPDATE EXCLUSIVE lock, and
  Postgres then proves SET NOT NULL from the validated constraint, so the
  ACCESS EXCLUSIVE lock never has to scan the table.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    UPDATE client_sessions cs SET actor_id = d.actor_id
    FROM devices d
    WHERE cs.actor_id IS NULL
      AND d.account_id = cs.account_id
      AND d.id = cs.device_id
    """)

    # DROP IF EXISTS first so a crash between ADD and DROP leaves the
    # migration safely re-runnable.
    execute(
      "ALTER TABLE client_sessions DROP CONSTRAINT IF EXISTS client_sessions_actor_id_not_null"
    )

    execute("""
    ALTER TABLE client_sessions
      ADD CONSTRAINT client_sessions_actor_id_not_null
      CHECK (actor_id IS NOT NULL) NOT VALID
    """)

    execute(
      "ALTER TABLE client_sessions VALIDATE CONSTRAINT client_sessions_actor_id_not_null"
    )

    execute("ALTER TABLE client_sessions ALTER COLUMN actor_id SET NOT NULL")
    execute("ALTER TABLE client_sessions DROP CONSTRAINT client_sessions_actor_id_not_null")
  end

  def down do
    execute("ALTER TABLE client_sessions ALTER COLUMN actor_id DROP NOT NULL")
  end
end
