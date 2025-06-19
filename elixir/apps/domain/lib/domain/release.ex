defmodule Domain.Release do
  require Logger

  @otp_app :domain
  @repos Application.compile_env!(@otp_app, :ecto_repos)

  def migrate(opts \\ []) do
    Application.ensure_all_started(:sentry)

    conditional =
      Keyword.get(
        opts,
        :conditional,
        Application.get_env(
          :domain,
          :run_conditional_migrations,
          System.get_env("RUN_CONDITIONAL_MIGRATIONS") == "true"
        )
      )

    for repo <- @repos do
      {:ok, _, _} = do_migration(repo, conditional)
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

  defp do_migration(repo, conditional) do
    default_path = priv_dir(@otp_app, ["repo", "migrations"])
    conditional_path = priv_dir(@otp_app, ["repo", "conditional_migrations"])

    paths =
      if conditional do
        [
          default_path,
          conditional_path
        ]
      else
        [
          default_path
        ]
      end

    Ecto.Migrator.with_repo(repo, fn repo ->
      Ecto.Migrator.run(repo, paths, :up, all: true)

      unless conditional do
        check_pending_conditional_migrations(@otp_app, repo)
      end
    end)
  end

  defp check_pending_conditional_migrations(app, repo) do
    conditional_path = priv_dir(app, ["repo", "conditional_migrations"])

    if File.dir?(conditional_path) do
      # Get all migrations from the conditional directory
      case Ecto.Migrator.migrations(repo, conditional_path) do
        [] ->
          :ok

        migrations ->
          # Count pending migrations (status = :down)
          Enum.count(migrations, fn {status, _, _} -> status == :down end)
          |> maybe_log_error()
      end
    end
  end

  defp maybe_log_error(0), do: nil

  defp maybe_log_error(pending) do
    error = """
      #{pending} pending conditional migration(s) were not run because run_conditional_migrations is false.
      Run the following command from an IEx shell when you're ready to execute them:

      Domain.Release.migrate(conditional: true)
    """

    Logger.error(error)

    # Sentry logger handler may not be fully initialized, so manually send
    # a message and wait for it to flush.
    Task.start(fn ->
      Sentry.capture_message(error)
    end)

    Process.sleep(1_000)
  end
end
