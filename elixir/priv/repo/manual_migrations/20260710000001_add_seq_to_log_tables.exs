defmodule Portal.Repo.Migrations.AddSeqToLogTables do
  @moduledoc """
  Adds a `seq` bigint to the four log tables, assigned from a per-table
  sequence on insert. Log sinks page each stream with a cursor over
  (account_id, seq): unlike the timestamp columns, seq follows arrival order,
  so rows that arrive late (e.g. flow reports spooled on an offline gateway)
  can never land behind an already-advanced cursor.

  The column and default are catalog-only changes; existing rows are then
  backfilled in chronological batches by a temporary procedure that commits
  per batch, so the migration is resumable and never holds a long
  transaction. NOT NULL is established through a validated CHECK constraint
  to avoid a full-table scan under ACCESS EXCLUSIVE. The (account_id, seq)
  indexes are created last so the backfill updates stay out of them.

  Every statement is idempotent; re-run after a crash and it resumes where it
  left off.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  @tables [
    {"change_logs", "account_id, log_id", "lsn"},
    {"session_logs", "account_id, log_id", ~s("timestamp")},
    {"api_request_logs", "account_id, log_id", "inserted_at"},
    # flow_logs' primary key is the 10-column flow identity, so its batch joins
    # go through the flow_logs_log_id_index secondary instead.
    {"flow_logs", "account_id, log_id", "flow_start"}
  ]

  def up do
    for {table, _key_cols, ord_col} <- @tables do
      execute("CREATE SEQUENCE IF NOT EXISTS #{table}_seq_seq")
      execute("ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS seq bigint")
      execute("ALTER SEQUENCE #{table}_seq_seq OWNED BY #{table}.seq")

      execute(
        "ALTER TABLE #{table} ALTER COLUMN seq SET DEFAULT nextval('#{table}_seq_seq')"
      )

      # Partial index so each backfill batch is a cheap ordered index scan
      # that shrinks as rows are filled in. CONCURRENTLY is not supported on
      # the partitioned flow_logs, which is small enough not to need it.
      execute(
        "CREATE INDEX #{concurrently(table)} IF NOT EXISTS #{table}_seq_backfill_index " <>
          "ON #{table} (#{ord_col}) WHERE seq IS NULL"
      )
    end

    execute("""
    CREATE OR REPLACE PROCEDURE backfill_log_seq(
      tbl regclass, key_cols text, ord_col text, seqname text
    )
    LANGUAGE plpgsql
    AS $$
    DECLARE
      remaining boolean;
      batch_count bigint;
      total bigint := 0;
      tkeys text := (SELECT string_agg('t.' || trim(c), ', ')
                     FROM unnest(string_to_array(key_cols, ',')) c);
      nkeys text := (SELECT string_agg('n.' || trim(c), ', ')
                     FROM unnest(string_to_array(key_cols, ',')) c);
    BEGIN
      LOOP
        -- nextval must run over the already-sorted subquery: a bare
        -- UPDATE ... WHERE key IN (ordered subquery) assigns seqs in heap
        -- scan order, discarding the chronology the subquery established.
        EXECUTE format(
          'WITH numbered AS (
             SELECT %s, nextval(%L) AS s
             FROM (
               SELECT %s FROM %s WHERE seq IS NULL ORDER BY %s LIMIT 10000
             ) b
           )
           UPDATE %s t SET seq = n.s FROM numbered n WHERE (%s) = (%s)',
          key_cols, seqname, key_cols, tbl, ord_col, tbl, tkeys, nkeys
        );
        GET DIAGNOSTICS batch_count = ROW_COUNT;

        COMMIT;
        total := total + batch_count;
        RAISE NOTICE 'Backfilled % rows of % so far', total, tbl;

        -- Terminate on emptiness rather than batch_count: a concurrent
        -- update can move selected rows so a batch updates fewer rows than
        -- it selected while NULL rows still remain.
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE seq IS NULL)', tbl)
        INTO remaining;

        EXIT WHEN NOT remaining;
      END LOOP;
    END;
    $$
    """)

    for {table, key_cols, ord_col} <- @tables do
      execute("CALL backfill_log_seq('#{table}', '#{key_cols}', '#{escape(ord_col)}', '#{table}_seq_seq')")
    end

    execute("DROP PROCEDURE backfill_log_seq(regclass, text, text, text)")

    for {table, _key_cols, _ord_col} <- @tables do
      execute("DROP INDEX #{concurrently(table)} IF EXISTS #{table}_seq_backfill_index")

      # Validated CHECK lets SET NOT NULL skip its full-table scan, so no
      # statement here takes more than a brief lock.
      execute("ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{table}_seq_not_null")

      execute(
        "ALTER TABLE #{table} ADD CONSTRAINT #{table}_seq_not_null " <>
          "CHECK (seq IS NOT NULL) NOT VALID"
      )

      execute("ALTER TABLE #{table} VALIDATE CONSTRAINT #{table}_seq_not_null")
      execute("ALTER TABLE #{table} ALTER COLUMN seq SET NOT NULL")
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_seq_not_null")

      execute(
        "CREATE INDEX #{concurrently(table)} IF NOT EXISTS #{table}_account_id_seq_index " <>
          "ON #{table} (account_id, seq)"
      )
    end
  end

  def down do
    for {table, _key_cols, _ord_col} <- @tables do
      execute("DROP INDEX #{concurrently(table)} IF EXISTS #{table}_account_id_seq_index")
      execute("DROP INDEX #{concurrently(table)} IF EXISTS #{table}_seq_backfill_index")
      execute("ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{table}_seq_not_null")
      execute("ALTER TABLE #{table} DROP COLUMN IF EXISTS seq")
      execute("DROP SEQUENCE IF EXISTS #{table}_seq_seq")
    end
  end

  defp concurrently("flow_logs"), do: ""
  defp concurrently(_table), do: "CONCURRENTLY"

  defp escape(sql), do: String.replace(sql, "'", "''")
end
