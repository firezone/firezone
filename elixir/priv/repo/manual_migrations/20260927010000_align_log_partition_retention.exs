defmodule Portal.Repo.Migrations.AlignLogPartitionRetention do
  use Ecto.Migration

  @disable_ddl_transaction true
  @sources ~w[session_logs api_request_logs change_logs]

  def up do
    for source <- @sources do
      parent = source <> "_partitioned"
      timestamp = if source == "api_request_logs", do: "inserted_at", else: "timestamp"

      # Extend already-activated mirrors before allowing older writes through
      # their triggers. Standalone creation and ATTACH avoid a long parent lock.
      for date <- Date.range(Date.add(Date.utc_today(), -121), Date.add(Date.utc_today(), -91)) do
        name = parent <> "_" <> Calendar.strftime(date, "%Y%m%d")
        lower = Date.to_iso8601(date) <> " 00:00:00+00"
        upper = Date.to_iso8601(Date.add(date, 1)) <> " 00:00:00+00"

        ddl(source, """
        CREATE TABLE IF NOT EXISTS #{name} (
          LIKE #{parent} INCLUDING DEFAULTS INCLUDING CONSTRAINTS,
          CONSTRAINT #{name}_bounds CHECK (#{timestamp} >= TIMESTAMPTZ '#{lower}'
                                         AND #{timestamp} < TIMESTAMPTZ '#{upper}')
        )
        """)

        ddl(source, "COMMENT ON TABLE #{name} IS 'Portal.Workers.PartitionLogTables'")

        ddl(source, """
        DO $$ BEGIN
          IF EXISTS (SELECT 1 FROM pg_inherits
                     WHERE inhrelid = '#{name}'::regclass AND inhparent = '#{parent}'::regclass
                       AND inhdetachpending) THEN
            ALTER TABLE #{parent} DETACH PARTITION #{name} FINALIZE;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM pg_inherits
                         WHERE inhrelid = '#{name}'::regclass AND inhparent = '#{parent}'::regclass) THEN
            ALTER TABLE #{parent} ATTACH PARTITION #{name}
              FOR VALUES FROM ('#{lower}') TO ('#{upper}');
          END IF;
        END $$
        """)
      end

      ddl(source, """
      DO $$ DECLARE original text; replacement text; BEGIN
        LOCK TABLE ONLY #{source} IN SHARE ROW EXCLUSIVE MODE;
        SELECT pg_get_functiondef('mirror_#{source}()'::regprocedure) INTO original;
        replacement := replace(original, '::date - 90', '::date - 121');
        IF position('::date - 121' in replacement) = 0 THEN
          RAISE EXCEPTION 'Unexpected mirror function for #{source}';
        END IF;
        IF replacement <> original THEN
          EXECUTE replacement;
          UPDATE log_partition_mirrors SET started_at = clock_timestamp()
            WHERE source_table = '#{source}';
        END IF;
      END $$
      """)
    end
  end

  def down do
    raise "Reducing log retention requires an explicit data-retention decision"
  end

  defp ddl(source, sql) do
    execute(fn ->
      {:ok, _} =
        repo().transaction(fn ->
          repo().query!("SET LOCAL lock_timeout = '1s'")
          # Serialize with backfill, cutover and partition maintenance.
          repo().query!(
            "SELECT pg_advisory_xact_lock(hashtextextended(current_schema() || '.' || $1, 0))",
            [source <> "_partitioned"]
          )

          repo().query!(sql, [], timeout: 60_000)
        end)
    end)
  end
end
