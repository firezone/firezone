defmodule Portal.LogPartitionMirrorFixtures do
  @moduledoc false
  alias Portal.Repo

  # Maintenance changes catalogs and DETACH CONCURRENTLY needs committed DDL.
  # Each test gets a private schema so it can run alongside other DB tests.
  def with_mirror_schema(source, fun) when source in ~w[session_logs api_request_logs change_logs] do
    schema = "log_mirror_#{System.unique_integer([:positive])}"
    parent = source <> "_partitioned"
    timestamp = if source == "api_request_logs", do: "inserted_at", else: "timestamp"
    [[old_path]] = Repo.query!("SHOW search_path").rows
    Repo.query!("CREATE SCHEMA #{schema}")

    try do
      Repo.query!("SELECT set_config('search_path', $1, false)", [schema])
      Repo.query!("CREATE TABLE accounts (id uuid PRIMARY KEY)")
      Repo.query!("CREATE TABLE log_partition_mirrors (source_table text PRIMARY KEY)")
      Repo.query!("INSERT INTO log_partition_mirrors VALUES ($1)", [source])
      Repo.query!("""
      CREATE TABLE #{parent} (
        LIKE public.#{source} INCLUDING DEFAULTS INCLUDING CONSTRAINTS,
        PRIMARY KEY (account_id, #{timestamp}, log_id),
        FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
      ) PARTITION BY RANGE (#{timestamp})
      """)
      Repo.query!("CREATE INDEX ON #{parent} (account_id, log_id)")
      Repo.query!("CREATE INDEX ON #{parent} (account_id, seq)")

      for date <- Date.range(Date.add(Date.utc_today(), -90), Date.add(Date.utc_today(), 14)) do
        name = parent <> "_" <> Calendar.strftime(date, "%Y%m%d")
        lower = Date.to_iso8601(date) <> " 00:00:00+00"
        upper = Date.to_iso8601(Date.add(date, 1)) <> " 00:00:00+00"
        Repo.query!("CREATE TABLE #{name} PARTITION OF #{parent} FOR VALUES FROM ('#{lower}') TO ('#{upper}')")
        Repo.query!("COMMENT ON TABLE #{name} IS 'Portal.Workers.PartitionLogMirrors'")
      end

      fun.(schema)
    after
      Repo.query!("SELECT set_config('search_path', $1, false)", [old_path])
      Repo.query!("DROP SCHEMA #{schema} CASCADE")
    end
  end
end
