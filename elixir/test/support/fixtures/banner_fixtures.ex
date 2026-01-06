defmodule Portal.BannerFixtures do
  @moduledoc """
  Test helpers for creating banners and related data.
  """

  def banner_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {:ok, banner} =
      %Portal.Actor{}
      |> Ecto.Changeset.cast(attrs, [:message])
      |> Portal.Banner.changeset()
      |> Portal.Repo.insert()

    banner
  end
end
