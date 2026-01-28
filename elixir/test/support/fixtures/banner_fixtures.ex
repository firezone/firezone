defmodule Portal.BannerFixtures do
  @moduledoc """
  Test helpers for creating banners and related data.
  """

  def banner_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {:ok, banner} =
      struct(Portal.Banner, attrs)
      |> Portal.Repo.insert(banner)

    banner
  end
end
