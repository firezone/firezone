defmodule Portal.LogPartitionMirrorFixtures do
  @moduledoc false
  alias Portal.Repo

  # Maintenance changes catalogs and DETACH CONCURRENTLY needs committed DDL.
  # Each test gets a private schema so it can run alongside other DB tests.
  def with_mirror_schema(source, fun) when source in ~w[flow_logs session_logs api_request_logs change_logs] do
    schema = "log_mirror_#{System.unique_integer([:positive])}"
    flow? = source == "flow_logs"
    parent = if flow?, do: source, else: source <> "_partitioned"
    timestamp = case source do
      "flow_logs" -> "flow_start"
      "api_request_logs" -> "inserted_at"
      _ -> "timestamp"
    end
    retention_days = 121
    [[old_path]] = Repo.query!("SHOW search_path").rows
    Repo.query!("CREATE SCHEMA #{schema}")

    try do
      Repo.query!("SELECT set_config('search_path', $1, false)", [schema])
      Repo.query!("CREATE TABLE accounts (id uuid PRIMARY KEY)")
      unless flow? do
        Repo.query!("CREATE TABLE log_partition_mirrors (source_table text PRIMARY KEY)")
        Repo.query!("INSERT INTO log_partition_mirrors VALUES ($1)", [source])
      end
      Repo.query!("""
      CREATE TABLE #{parent} (
        LIKE public.#{source} INCLUDING DEFAULTS INCLUDING CONSTRAINTS,
        PRIMARY KEY (account_id, #{timestamp}, log_id),
        FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
      ) PARTITION BY RANGE (#{timestamp})
      """)
      Repo.query!("CREATE INDEX ON #{parent} (account_id, log_id)")
      Repo.query!("CREATE INDEX ON #{parent} (account_id, seq)")

      for date <- Date.range(Date.add(Date.utc_today(), -retention_days), Date.add(Date.utc_today(), 14)) do
        name = parent <> "_" <> Calendar.strftime(date, "%Y%m%d")
        lower = Date.to_iso8601(date) <> " 00:00:00+00"
        upper = Date.to_iso8601(Date.add(date, 1)) <> " 00:00:00+00"
        Repo.query!("CREATE TABLE #{name} PARTITION OF #{parent} FOR VALUES FROM ('#{lower}') TO ('#{upper}')")
        # Existing flow partitions have no ownership comment. Mirror fixtures
        # use the original marker to cover compatibility with the first PR revision.
        unless flow?, do: Repo.query!("COMMENT ON TABLE #{name} IS 'Portal.Workers.PartitionLogMirrors'")
      end

      fun.(schema)
    after
      Repo.query!("SELECT set_config('search_path', $1, false)", [old_path])
      Repo.query!("DROP SCHEMA #{schema} CASCADE")
    end
  end
end
