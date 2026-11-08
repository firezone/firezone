Ecto.Adapters.SQL.Sandbox.mode(Portal.Repo, :manual)

# Job lifecycle logs likewise fan out to all concurrent log captures. Worker
# logs and telemetry events remain available to the tests that assert on them.
:ok = Oban.Telemetry.detach_default_logger()

# Print connection count to help debug "too many clients" errors
:ok = Ecto.Adapters.SQL.Sandbox.checkout(Portal.Repo)

# Get current database name from config to filter the count
db_name = Portal.Repo.config()[:database]

# Filter pg_stat_activity by database name to isolate test connections from dev server
query = "SELECT count(*) FROM pg_stat_activity WHERE datname = $1"

case Ecto.Adapters.SQL.query(Portal.Repo, query, [db_name], log: false) do
  {:ok, %{rows: [[count]]}} ->
    IO.puts("--- Active connections to #{db_name}: #{count} (Limit is usually 100) ---")

  error ->
    IO.puts("Could not fetch connection count:")
    IO.inspect(error)
end

Ecto.Adapters.SQL.Sandbox.checkin(Portal.Repo)

# Migration-created partitions age as a developer reuses the test database.
# Extend the ingestion window before any sandbox transactions take locks.
Ecto.Adapters.SQL.Sandbox.unboxed_run(Portal.Repo, fn ->
  for date <- Portal.Workers.PartitionLogTables.ingestion_dates(Date.utc_today()) do
    name = "flow_logs_" <> Calendar.strftime(date, "%Y%m%d")
    lower = Date.to_iso8601(date) <> " 00:00:00+00"
    upper = Date.to_iso8601(Date.add(date, 1)) <> " 00:00:00+00"

    Portal.Repo.query!(
      "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF flow_logs FOR VALUES FROM ('#{lower}') TO ('#{upper}')",
      [],
      log: false
    )
  end
end)

{:ok, _pid} = Registry.start_link(keys: :unique, name: Portal.Test.QueueRegistry)

# Before any test opens a sandbox transaction, see the module doc.
{:ok, _pid} = Portal.Test.LogicalSlots.start()

ExUnit.start(formatters: [ExUnit.CLIFormatter, JUnitFormatter])
