defmodule Portal.BannerFixtures do
  @moduledoc """
  Test helpers for creating banners and related data.
  """

  def valid_banner_attrs do
    %{
      message: "This is a test banner message."
    }
  end

  def banner_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, valid_banner_attrs())

    %Portal.Banner{}
    |> Ecto.Changeset.cast(attrs, [:message])
    |> Portal.Repo.insert!()
  end
end
