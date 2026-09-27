defmodule Portal.Repo.Migrations.CreateLogPartitionMirrors do
  use Ecto.Migration

  @moduledoc """
  First phase of partitioning the remaining log streams. Reads and retention
  remain on the original tables. AFTER triggers mirror committed mutations,
  including writes from releases that predate this migration. No backfill or
  cutover is performed here.

  Run with Portal.Release.migrate(manual: true). Each DDL operation has a short
  lock timeout and commits separately; rerun after a lock timeout. Activation
  and its coverage timestamp commit together, only after every partition and
  constraint is ready. Existing activation timestamps are never reset.
  """

  @disable_ddl_transaction true

  @tables [
    {"session_logs", "timestamp", "account_id, timestamp, log_id"},
    {"api_request_logs", "inserted_at", "account_id, inserted_at, log_id"},
    {"change_logs", "timestamp", "timestamp, lsn"}
  ]

  def up do
    ddl("""
    CREATE TABLE IF NOT EXISTS log_partition_mirrors (
      source_table text PRIMARY KEY,
      started_at timestamptz NOT NULL DEFAULT clock_timestamp()
    )
    """)

    for {source, timestamp, conflict} <- @tables do
      mirror = source <> "_partitioned"

      # Copy defaults (including the ORIGINAL seq sequence), nullability and
      # checks, but not the old indexes or PK, which omit the partition key.
      ddl("""
      CREATE TABLE IF NOT EXISTS #{mirror}
        (LIKE #{source} INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
        PARTITION BY RANGE (#{timestamp})
      """)

      ddl("""
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = '#{mirror}'::regclass AND contype = 'p') THEN
          ALTER TABLE #{mirror} ADD PRIMARY KEY (account_id, #{timestamp}, log_id);
        END IF;
      END $$
      """)

      ddl("CREATE INDEX IF NOT EXISTS #{mirror}_account_id_log_id_index ON #{mirror} (account_id, log_id)")
      ddl("CREATE INDEX IF NOT EXISTS #{mirror}_account_id_seq_index ON #{mirror} (account_id, seq)")

      if source == "change_logs" do
        # A replay carries the same WAL commit timestamp and LSN, even when
        # the restarted consumer assigns a different public log_id.
        ddl("CREATE UNIQUE INDEX IF NOT EXISTS #{mirror}_timestamp_lsn_index ON #{mirror} (timestamp, lsn)")
      end

      # Individual transactions keep accounts FK locks and parent DDL locks
      # out of the entire seeding loop. No source-table writes are mirrored yet.
      for date <- Date.range(Date.add(Date.utc_today(), -90), Date.add(Date.utc_today(), 14)) do
        name = mirror <> "_" <> Calendar.strftime(date, "%Y%m%d")
        lower = Date.to_iso8601(date) <> " 00:00:00+00"
        upper = Date.to_iso8601(Date.add(date, 1)) <> " 00:00:00+00"

        ddl("""
        CREATE TABLE IF NOT EXISTS #{name} PARTITION OF #{mirror}
          FOR VALUES FROM ('#{lower}') TO ('#{upper}')
        """)

        ddl("COMMENT ON TABLE #{name} IS 'Portal.Workers.PartitionLogTables'")
      end

      ddl("""
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = '#{mirror}'::regclass AND contype = 'f') THEN
          ALTER TABLE #{mirror} ADD CONSTRAINT #{mirror}_account_id_fkey
            FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE;
        END IF;
      END $$
      """)

      # All columns are copied from the stored row, including DB-generated
      # timestamps and seq. A mirror must never allocate its own sequence value.
      ddl("""
      CREATE OR REPLACE FUNCTION mirror_#{source}() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
          DELETE FROM #{mirror}
          WHERE account_id = OLD.account_id AND #{timestamp} = OLD.#{timestamp}
            AND log_id = OLD.log_id;
        END IF;

        -- Do not recreate expired partitions for old WAL replays. Include the
        -- entire boundary day, matching partition retention in UTC.
        IF TG_OP <> 'DELETE' AND NEW.#{timestamp} >=
          ((clock_timestamp() AT TIME ZONE 'UTC')::date - 90)::timestamp AT TIME ZONE 'UTC'
        THEN
          INSERT INTO #{mirror} SELECT NEW.* ON CONFLICT (#{conflict}) DO NOTHING;
        END IF;
        RETURN NULL;
      END $$
      """)

      ddl("""
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_trigger
                       WHERE tgrelid = '#{source}'::regclass AND tgname = 'mirror_partitioned_logs') THEN
          CREATE TRIGGER mirror_partitioned_logs AFTER INSERT OR UPDATE OR DELETE ON #{source}
            FOR EACH ROW EXECUTE FUNCTION mirror_#{source}();
          INSERT INTO log_partition_mirrors (source_table) VALUES ('#{source}');
        END IF;
      END $$
      """)
    end
  end

  # Phase one has no reads from the mirrors. Remove triggers before dropping
  # them. LIKE's shared sequence default does not transfer sequence ownership.
  def down do
    for {source, _timestamp, _conflict} <- Enum.reverse(@tables) do
      ddl("DROP TRIGGER IF EXISTS mirror_partitioned_logs ON #{source}")
      ddl("DROP FUNCTION IF EXISTS mirror_#{source}()")
      ddl("DROP TABLE IF EXISTS #{source}_partitioned")
    end

    ddl("DROP TABLE IF EXISTS log_partition_mirrors")
  end

  defp ddl(sql) do
    execute(fn ->
      {:ok, _} = repo().transaction(fn ->
        repo().query!("SET LOCAL lock_timeout = '1s'")
        repo().query!(sql, [], timeout: 60_000)
      end)
    end)
  end
end
