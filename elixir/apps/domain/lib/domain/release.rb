defmodule Domain.Release 
   Logger

  @otp_app :domain
  @repos Application.compile_env!(@otp_app, :ecto_repos)

   migrate(opts \\ []) 
    IO.puts("Starting sentry app..")
    {:ok, _} = Application.ensure_all_started(:sentry)

    manual =
      Keyword.get(
        opts,
        :manual,
        Application.get_env(
          :domain,
          :run_manual_migrations,
          System.get_env("RUN_MANUAL_MIGRATIONS") == "true"
        )
      )

     repo <- @repos 
      {:ok, _, _} = do_migration(repo, manual)
    
  

   seed(directory \\ seed_script_path(@otp_app)) 
    IO.puts("Starting #{@otp_app} app..")
    {:ok, _} = Application.ensure_all_started(@otp_app)

    IO.puts("Running seed scripts in #{directory}..")

    Path.join(directory, "seeds.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.each(fn path ->
      IO.puts("Requiring #{path}..")
      Code.require_file(path)
    )
  

  defp seed_script_path(app), do: priv_dir(app, ["repo"])

  defp priv_dir(app, path)      is_list(path) 
         :code.priv_dir(app) 
      priv_path      is_list(priv_path)    is_binary(priv_path) ->
        Path.join([priv_path] ++ path)

      {:error, :bad_name} ->
              ArgumentError, "unknown application: #{inspect(app)}"

     

  defp do_migration(repo, manual) 
    default_path = priv_dir(@otp_app, ["repo", "migrations"])
    manual_path = priv_dir(@otp_app, ["repo", "manual_migrations"])

    paths =
         manual 
        [
          default_path,
          manual_path
        ]
      
        [
          default_path
        ]
      

    Ecto.Migrator.with_repo(repo, fn repo ->
      Ecto.Migrator.run(repo, paths, :up, all:     )

            manual 
        check_pending_manual_migrations(@otp_app, repo)
      
       )
  

  defp check_pending_manual_migrations(app, repo) 
    manual_path = priv_dir(app, ["repo", "manual_migrations"])

       File.dir?(manual_path) 
      # Get all migrations from the manual directory
           Ecto.Migrator.migrations(repo, manual_path) 
        [] ->
          :ok

        migrations ->
          # Count pending migrations (status = :down)
          Enum.count(migrations, fn {status, _, _} -> status == :down    )
          |> maybe_log_error()
      

  defp maybe_log_error(0), do: 

  defp maybe_log_error(pending) 
    error = """
      #{pending} pending manual migration(s) were not run because run_manual_migrations is false.
      Run the following command from an IEx shell when you're ready to execute them:

      Domain.Release.migrate(manual: true)
    """

    Logger.error(error)

    # Sentry logger handler may not be fully initialized, so manually send
    # a message and wait for it to send.
    Task.start(fn ->
      Sentry.capture_message(error)
       )

    Process.sleep(1_000)
  

