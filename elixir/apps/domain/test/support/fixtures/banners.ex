defmodule Domain.Fixtures.Banners do
  import Ecto.Changeset
  use Domain.Fixture

  def create_banner(attrs \\ %{}) do
    cast(%Domain.Banner{}, Enum.into(attrs, %{}), [:message])
    |> Domain.Repo.insert!()
  end
end
