defmodule Portal.Repo.Migrations.EnforceSessionTimestamps do
  @moduledoc """
  Makes the session `timestamp` columns NOT NULL and drops the inserted_at
  indexes that the timestamp indexes replaced.

  Run this only after the release that writes `timestamp` on every session
  insert is fully rolled out: pods from the previous release insert session
  rows without a timestamp, so enforcing NOT NULL during the rollout window
  would fail their queue flushes. The first step sweeps any rows those pods
  wrote after the deploy-time backfill ran.

  NOT NULL is applied via a NOT VALID check constraint that is validated
  separately: VALIDATE only takes a SHARE UPDATE EXCLUSIVE lock, and
  Postgres then proves SET NOT NULL from the validated constraint, so the
  ACCESS EXCLUSIVE lock never has to scan the table.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @tables ~w[client_sessions gateway_sessions portal_sessions]

  def up do
    for table <- @tables do
      execute("UPDATE #{table} SET \"timestamp\" = inserted_at WHERE \"timestamp\" IS NULL")

      # DROP IF EXISTS first so a crash between ADD and DROP leaves the
      # migration safely re-runnable.
      execute("ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{table}_timestamp_not_null")

      execute("""
      ALTER TABLE #{table}
        ADD CONSTRAINT #{table}_timestamp_not_null
        CHECK ("timestamp" IS NOT NULL) NOT VALID
      """)

      execute("ALTER TABLE #{table} VALIDATE CONSTRAINT #{table}_timestamp_not_null")
      execute("ALTER TABLE #{table} ALTER COLUMN \"timestamp\" SET NOT NULL")
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_timestamp_not_null")
    end

    execute("DROP INDEX CONCURRENTLY IF EXISTS client_sessions_inserted_at_index")

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS client_sessions_account_id_device_id_inserted_at_index"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS gateway_sessions_inserted_at_index")

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS gateway_sessions_account_id_device_id_inserted_at_index"
    )
  end

  def down do
    for table <- @tables do
      execute("ALTER TABLE #{table} ALTER COLUMN \"timestamp\" DROP NOT NULL")
    end
  end
end
