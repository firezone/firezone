defmodule Portal.Repo.Migrations.RemoveLogPartitionRolloutState do
  use Ecto.Migration

  @disable_ddl_transaction true
  @retired_workers ~w[Portal.Workers.DeleteOldSessionLogs Portal.Workers.DeleteOldAPIRequestLogs Portal.Workers.DeleteOldChangeLogs Portal.Workers.PartitionFlowLogs]

  def up do
    execute(fn ->
      {:ok, _} =
        repo().transaction(
          fn ->
            repo().query!("SET LOCAL lock_timeout = '1s'")
            repo().query!("SET LOCAL statement_timeout = '10s'")

            repo().query!(
              """
              DO $$ DECLARE source text; canonical oid; legacy oid; checkpoint jsonb; partition record; BEGIN
                IF EXISTS (SELECT 1 FROM oban_jobs WHERE worker = ANY(ARRAY[#{Enum.map_join(@retired_workers, ",", &"'#{&1}'")}])
                           AND state = 'executing') THEN
                  RAISE EXCEPTION 'Retired log jobs are still executing; drain them before cleanup';
                END IF;
                FOREACH source IN ARRAY ARRAY['session_logs', 'api_request_logs', 'change_logs'] LOOP
                  PERFORM pg_advisory_xact_lock(hashtextextended(current_schema() || '.' || source || '_partitioned', 0));
                  EXECUTE format('LOCK TABLE ONLY %I IN ACCESS SHARE MODE', source);
                  canonical := to_regclass(source);
                  legacy := to_regclass(source || '_legacy');
                  IF NOT EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = canonical) THEN
                    RAISE EXCEPTION 'Log table % has not been cut over', source;
                  END IF;
                  IF pg_get_serial_sequence(source, 'seq') IS NULL THEN
                    RAISE EXCEPTION 'Log table % does not own its sequence', source;
                  END IF;
                  IF to_regclass(source || '_partitioned') IS NOT NULL THEN
                    RAISE EXCEPTION 'Unexpected remaining mirror for %', source;
                  END IF;
                  IF to_regclass('log_table_backfills') IS NOT NULL THEN
                    SELECT to_jsonb(b) INTO checkpoint FROM log_table_backfills b WHERE source_table = source;
                    IF checkpoint->>'phase' IS DISTINCT FROM 'cutover'
                       OR (checkpoint->'context'->>'mirror_oid')::oid IS DISTINCT FROM canonical
                       OR (legacy IS NOT NULL AND (checkpoint->'context'->>'source_oid')::oid IS DISTINCT FROM legacy) THEN
                      RAISE EXCEPTION 'Unexpected cutover state for %', source;
                    END IF;
                  ELSIF legacy IS NOT NULL THEN
                    RAISE EXCEPTION 'Missing cutover identity for legacy table %', source;
                  END IF;
                  IF legacy IS NOT NULL THEN
                    EXECUTE format('DROP TABLE %I', source || '_legacy');
                  END IF;
                  EXECUTE format('DROP FUNCTION IF EXISTS %I()', 'mirror_' || source);
                END LOOP;
                -- Normalize old ownership markers so maintenance needs one convention.
                FOR partition IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = current_schema() AND c.relkind = 'r'
                    AND obj_description(c.oid, 'pg_class') = 'Portal.Workers.PartitionLogMirrors'
                    AND c.relname ~ '^(flow_logs|(session_logs|api_request_logs|change_logs)_partitioned)_[0-9]{8}$'
                LOOP
                  EXECUTE format('COMMENT ON TABLE %I IS %L', partition.relname, 'Portal.Workers.PartitionLogTables');
                END LOOP;
                DROP TABLE IF EXISTS log_table_backfills;
                DROP TABLE IF EXISTS log_partition_mirrors;
              END $$
              """,
              [],
              timeout: 60_000
            )
          end,
          timeout: 60_000
        )

      delete_retired_jobs()
    end)
  end

  def down,
    do: raise("Log partition cleanup is irreversible; legacy rows and rollout state were removed")

  defp delete_retired_jobs do
    {:ok, result} =
      repo().transaction(
        fn ->
          repo().query!("SET LOCAL lock_timeout = '1s'")

          repo().query!(
            """
            DELETE FROM oban_jobs WHERE id IN (
              SELECT id FROM oban_jobs WHERE worker = ANY($1::text[]) ORDER BY id LIMIT 5000
            )
            """,
            [@retired_workers],
            timeout: 60_000
          )
        end,
        timeout: 60_000
      )

    if result.num_rows > 0, do: delete_retired_jobs()
  end
end
