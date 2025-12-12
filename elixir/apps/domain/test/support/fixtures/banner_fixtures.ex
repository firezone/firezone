defmodule Domain.BannerFixtures do
  @moduledoc """
  Test helpers for creating banners and related data.
  """

  def banner_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {:ok, banner} =
      %Domain.Actor{}
      |> Ecto.Changeset.cast(attrs, [:message])
      |> Domain.Banner.changeset()
      |> Domain.Repo.insert()

    banner
  end
end
