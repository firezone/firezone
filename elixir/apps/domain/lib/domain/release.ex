defmodule Domain.Release do
  require Logger

  @otp_app :domain
  @repos Application.compile_env!(@otp_app, :ecto_repos)

  def migrate do
    for repo <- @repos do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def run_app(file_name, directory \\ seed_script_path(@otp_app)) do
    IO.puts("Starting #{@otp_app} app..")
    {:ok, _} = Application.ensure_all_started(@otp_app)

    IO.puts("Running seed scripts in #{directory}..")

    Path.join(directory, file_name)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.each(fn path ->
      IO.puts("Requiring #{path}..")
      Code.require_file(path)
    end)
  end

  def gateway_token(directory \\ seed_script_path(@otp_app)),
    do: run_app("gateway_token.exs", directory)

  def relay_token(directory \\ seed_script_path(@otp_app)),
    do: run_app("relay_token.exs", directory)

  def headless_token(directory \\ seed_script_path(@otp_app)),
    do: run_app("headless_token.exs", directory)

  def seed(directory \\ seed_script_path(@otp_app)), do: run_app("seeds.exs", directory)

  defp seed_script_path(app), do: priv_dir(app, ["repo"])

  defp priv_dir(app, path) when is_list(path) do
    case :code.priv_dir(app) do
      priv_path when is_list(priv_path) or is_binary(priv_path) ->
        Path.join([priv_path] ++ path)

      {:error, :bad_name} ->
        raise ArgumentError, "unknown application: #{inspect(app)}"
    end
  end
end
