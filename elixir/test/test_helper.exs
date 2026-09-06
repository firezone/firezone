Ecto.Adapters.SQL.Sandbox.mode(Portal.Repo, :manual)

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

ExUnit.start(formatters: [ExUnit.CLIFormatter, JUnitFormatter])
