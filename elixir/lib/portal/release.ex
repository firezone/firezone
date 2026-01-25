defmodule Portal.Release do
  require Logger

  @otp_app :portal
  @repos Application.compile_env!(@otp_app, :ecto_repos)

  def migrate(opts \\ []) do
    IO.puts("Starting sentry app..")
    {:ok, _} = Application.ensure_all_started(:sentry)

    manual =
      Keyword.get(
        opts,
        :manual,
        Application.get_env(
          :portal,
          :run_manual_migrations,
          System.get_env("RUN_MANUAL_MIGRATIONS") == "true"
        )
      )

    # Filter out read-only repos (like Replica) - they share the same database
    # and should not have migrations run against them
    repos = Enum.reject(@repos, &read_only_repo?/1)

    for repo <- repos do
      {:ok, _, _} = do_migration(repo, manual)
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

  defp do_migration(repo, manual) do
    default_path = priv_dir(@otp_app, ["repo", "migrations"])
    manual_path = priv_dir(@otp_app, ["repo", "manual_migrations"])

    paths =
      if manual do
        [
          default_path,
          manual_path
        ]
      else
        [
          default_path
        ]
      end

    Ecto.Migrator.with_repo(repo, fn repo ->
      Ecto.Migrator.run(repo, paths, :up, all: true)

      unless manual do
        check_pending_manual_migrations(@otp_app, repo)
      end
    end)
  end

  defp check_pending_manual_migrations(app, repo) do
    manual_path = priv_dir(app, ["repo", "manual_migrations"])

    if File.dir?(manual_path) do
      # Get all migrations from the manual directory
      case Ecto.Migrator.migrations(repo, manual_path) do
        [] ->
          :ok

        migrations ->
          # Count pending migrations (status = :down)
          Enum.count(migrations, fn {status, _, _} -> status == :down end)
          |> maybe_log_error()
      end
    end
  end

  defp read_only_repo?(repo) do
    function_exported?(repo, :read_only?, 0) and repo.read_only?()
  end

  defp maybe_log_error(0), do: nil

  defp maybe_log_error(pending) do
    error = """
      #{pending} pending manual migration(s) were not run because run_manual_migrations is false.
      Run the following command from an IEx shell when you're ready to execute them:

      Portal.Release.migrate(manual: true)
    """

    Logger.error(error)

    # Sentry logger handler may not be fully initialized, so manually send
    # a message and wait for it to send.
    Task.start(fn ->
      Sentry.capture_message(error)
    end)

    Process.sleep(1_000)
  end
end
