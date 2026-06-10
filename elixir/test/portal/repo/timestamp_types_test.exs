defmodule Portal.Repo.TimestampTypesTest do
  use Portal.DataCase, async: true

  # Oban manages its own schema; schema_migrations is Ecto-managed.
  @excluded_tables ~w[oban_jobs oban_peers schema_migrations]

  test "all app-owned datetime columns are timestamptz" do
    # Plain `timestamp` columns only stay correct as long as every SQL-level
    # interaction (defaults, casts, now() comparisons, range expressions) is
    # manually pinned to UTC; one missed pin silently corrupts instants on a
    # non-UTC server. New columns must be timestamptz, matching the
    # migration_timestamps repo default.
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name || '.' || column_name
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND data_type = 'timestamp without time zone'
          AND table_name != ALL($1)
        ORDER BY 1
        """,
        [@excluded_tables]
      )

    assert rows == [],
           "expected no plain timestamp columns, found: #{inspect(List.flatten(rows))}"
  end
end
