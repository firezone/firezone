defmodule Portal.Repo.Migrations.RequirePartitionedLogTables do
  use Ecto.Migration

  # Read-only deployment gate: this release no longer supports legacy parents.
  def up do
    execute("""
    DO $$ DECLARE source text; BEGIN
      FOREACH source IN ARRAY ARRAY['session_logs', 'api_request_logs', 'change_logs'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = to_regclass(source)) THEN
          RAISE EXCEPTION 'Complete log-table cutover with the preceding release before deploying cleanup: %', source;
        END IF;
      END LOOP;
    END $$
    """)
  end

  def down, do: :ok
end
