defmodule Portal.IsolatedLogDatabaseFixtures do
  @moduledoc false

  alias Portal.Repo

  # FINALIZE waits for old snapshots throughout the database, even when they
  # only touch unrelated schemas. Give real detach tests their own database.
  def start_isolated_repo(sources, opts \\ []) do
    connection_opts =
      Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database, :socket_dir])

    {:ok, admin} = Postgrex.start_link(connection_opts)
    database = "log_test_" <> String.replace(Ecto.UUID.generate(), "-", "")

    definitions =
      for source <- sources do
        unless source in ~w[flow_logs session_logs api_request_logs change_logs],
          do: raise("Unexpected log table")

        columns =
          Postgrex.query!(
            admin,
            """
            SELECT format('%I %s%s%s', a.attname, format_type(a.atttypid, a.atttypmod),
                          CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END,
                          CASE WHEN d.adbin IS NOT NULL AND a.attname <> 'seq'
                               THEN ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid) ELSE '' END)
            FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = $1::text::regclass AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """,
            ["public." <> source]
          ).rows
          |> List.flatten()

        constraints =
          Postgrex.query!(
            admin,
            """
            SELECT pg_get_constraintdef(oid) FROM pg_constraint
            WHERE conrelid = $1::text::regclass AND contype IN ('p', 'u', 'c')
            """,
            ["public." <> source]
          ).rows
          |> List.flatten()

        "CREATE TABLE public.#{source} (#{Enum.join(columns ++ constraints, ", ")})"
      end

    Postgrex.query!(admin, "CREATE DATABASE #{database} TEMPLATE template0", [])
    GenServer.stop(admin)

    ExUnit.Callbacks.on_exit(fn ->
      {:ok, admin} = Postgrex.start_link(connection_opts)

      try do
        Postgrex.query!(admin, "DROP DATABASE #{database} WITH (FORCE)", [])
      after
        GenServer.stop(admin)
      end
    end)

    {:ok, setup} = Postgrex.start_link(Keyword.put(connection_opts, :database, database))

    try do
      for definition <- definitions, do: Postgrex.query!(setup, definition, [])
    after
      GenServer.stop(setup)
    end

    {:ok, repo} =
      Repo.start_link(
        Keyword.merge(
          [name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: 3],
          opts
        )
      )

    repo
  end
end
