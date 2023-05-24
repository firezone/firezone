defmodule Domain.Release do
  require Logger

  @repos Application.compile_env!(:domain, :ecto_repos)

  def migrate do
    for repo <- @repos do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end
end
