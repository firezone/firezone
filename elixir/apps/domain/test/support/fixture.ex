defmodule Domain.Fixture do
  alias Domain.Repo

  def update!(schema, changes) do
    schema
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end
end
