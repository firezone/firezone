defmodule FgHttp.Release do
  @moduledoc """
  Configures the Mix Release or something
  """

  @app :fg_http

  def gen_secret(length) when length > 31 do
    IO.puts(:crypto.strong_rand_bytes(length) |> Base.encode64() |> binary_part(0, length))
  end

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
