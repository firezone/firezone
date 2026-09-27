defmodule Portal.Repo.Migrations.PrepareLogTableCutover do
  use Ecto.Migration

  @moduledoc """
  Prepares checkpoints for the following batched backfill migration.
  This migration does not copy data or rename a live table.
  """

  def up do
    execute("SET LOCAL lock_timeout = '1s'")

    execute("""
    CREATE TABLE log_table_backfills (
      source_table text PRIMARY KEY,
      context jsonb NOT NULL,
      phase text NOT NULL CHECK (phase IN ('copy', 'verify_source', 'verify_mirror', 'analyze', 'ready', 'cutover')),
      upper_account_id uuid,
      upper_log_id bytea,
      cursor_account_id uuid,
      cursor_log_id bytea,
      scanned_rows bigint NOT NULL DEFAULT 0,
      verified_rows bigint NOT NULL DEFAULT 0,
      ready_at timestamptz,
      cutover_at timestamptz,
      legacy_dropped_at timestamptz
    )
    """)
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM log_table_backfills WHERE cutover_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Log tables have been cut over; restoring an old table would lose newer writes';
      END IF;
    END $$
    """)

    drop(table(:log_table_backfills))
  end
end
