defmodule Domain.Release do
  require Logger

  @otp_app :domain
  @repos Application.compile_env!(@otp_app, :ecto_repos)

  def migrate(opts \\ []) do
    conditional =
      Keyword.get(
        opts,
        :conditional,
        Application.get_env(:domain, :run_conditional_migrations, false)
      )

    for repo <- @repos do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          &Ecto.Migrator.run(&1, migration_paths(@otp_app, conditional), :up, all: true)
        )
    end

    unless conditional do
      for repo <- @repos do
        check_pending_conditional_migrations(@otp_app, repo)
      end
    end
  end

  def seed(directory \\ seed_script_path(@otp_app)) do
    IO.puts("Starting #{@otp_app} app..")
    {:ok, _} = Application.ensure_all_started(@otp_app)

    IO.puts("Running seed scripts in #{directory}..")

    Path.join(directory, "seeds.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.each(fn path ->
      IO.puts("Requiring #{path}..")
      Code.require_file(path)
    end)
  end

  defp seed_script_path(app), do: priv_dir(app, ["repo"])

  defp priv_dir(app, path) when is_list(path) do
    case :code.priv_dir(app) do
      priv_path when is_list(priv_path) or is_binary(priv_path) ->
        Path.join([priv_path] ++ path)

      {:error, :bad_name} ->
        raise ArgumentError, "unknown application: #{inspect(app)}"
    end
  end

  defp migration_paths(app, true) do
    [
      priv_dir(app, ["repo", "migrations"]),
      priv_dir(app, ["repo", "conditional_migrations"])
    ]
  end

  defp migration_paths(app, false) do
    [
      priv_dir(app, ["repo", "migrations"])
    ]
  end

  defp check_pending_conditional_migrations(app, repo) do
    conditional_path = priv_dir(app, ["repo", "conditional_migrations"])

    # Check if the directory exists
    if File.dir?(conditional_path) do
      # Get all migrations from the conditional directory
      case Ecto.Migrator.migrations(repo, conditional_path) do
        [] ->
          :ok

        migrations ->
          # Count pending migrations (status = :down)
          pending = Enum.count(migrations, fn {status, _, _} -> status == :down end)

          if pending > 0 do
            Logger.warning("""
              #{pending} pending conditional migration(s) were not run because run_conditional_migrations is false.
              Run the following command from an IEx shell when you're ready to execute them:

              Domain.Release.migrate(conditional: true)
            """)
          end
      end
    end
  end
end
