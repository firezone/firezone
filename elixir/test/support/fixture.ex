defmodule Portal.Fixture do
  alias Portal.Repo

  defmacro __using__(_opts) do
    quote do
      import Portal.Fixture
      alias Portal.Repo
      alias Portal.Fixtures
    end
  end

  def update!(schema, changes) do
    schema
    |> Ecto.Changeset.change(Enum.into(changes, %{}))
    |> Repo.update!()
  end

  def unique_integer do
    System.unique_integer([:positive, :monotonic])
  end

end
