defmodule Portal.LogPartitionMirrorActivationTest do
  use ExUnit.Case, async: true

  alias Portal.Repo
  alias Portal.Repo.Migrations.CreateLogPartitionMirrors, as: Migration

  unless Code.ensure_loaded?(Migration) do
    Code.require_file("priv/repo/manual_migrations/20260927000000_create_log_partition_mirrors.exs")
  end

  @version 20260927000000
  @sources ~w[session_logs api_request_logs change_logs]

  test "migration reruns repair partial activation without claiming interrupted coverage" do
    # Run the actual nontransactional migration in a private schema/pool. Every
    # migration connection must use this search_path, including the runner task.
    schema = "log_activation_#{System.unique_integer([:positive])}"
    {:ok, repo} = Repo.start_link(
      name: nil,
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      parameters: [search_path: schema]
    )
    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      Repo.query!("CREATE SCHEMA #{schema}")
      Repo.query!("CREATE TABLE accounts (id uuid PRIMARY KEY)")

      for source <- @sources do
        Repo.query!("CREATE TABLE #{source} (LIKE public.#{source} INCLUDING ALL)")
      end

      assert :ok = migrate(schema)
      original = markers()
      assert map_size(original) == 3

      # An interrupted migration can commit activation before Ecto records the
      # migration version. An ordinary retry must preserve all coverage starts.
      assert :ok = rerun(schema)
      assert markers() == original

      # These half-states require external changes; normal activation creates
      # the trigger and marker atomically. Still repair them safely on a retry.
      Repo.query!("DELETE FROM log_partition_mirrors WHERE source_table = 'session_logs'")
      Repo.query!("DROP TRIGGER mirror_partitioned_logs ON api_request_logs")
      [[before_repair]] = Repo.query!("SELECT clock_timestamp()").rows

      assert :ok = rerun(schema)
      repaired = markers()
      assert DateTime.compare(repaired["session_logs"], before_repair) in [:eq, :gt]
      assert DateTime.compare(repaired["api_request_logs"], before_repair) in [:eq, :gt]
      assert repaired["change_logs"] == original["change_logs"]

      for source <- @sources do
        assert [[true]] = Repo.query!("""
        SELECT EXISTS (SELECT 1 FROM pg_trigger
                       WHERE tgrelid = $1::text::regclass
                         AND tgname = 'mirror_partitioned_logs' AND tgenabled = 'O')
        """, [source]).rows
      end

      assert :ok = rerun(schema)
      assert markers() == repaired
    after
      try do
        Repo.query!("DROP SCHEMA IF EXISTS #{schema} CASCADE")
      after
        Repo.put_dynamic_repo(previous_repo)
        GenServer.stop(repo)
      end
    end
  end

  defp migrate(schema), do: Ecto.Migrator.up(Repo, @version, Migration, prefix: schema, log: false)

  defp rerun(schema) do
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    migrate(schema)
  end

  defp markers do
    Repo.query!("SELECT source_table, started_at FROM log_partition_mirrors").rows
    |> Map.new(fn [source, started_at] -> {source, started_at} end)
  end
end
