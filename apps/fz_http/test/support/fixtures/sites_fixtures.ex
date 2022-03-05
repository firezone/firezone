defmodule FzHttp.SitesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.Sites` context.
  """

  alias FzHttp.Sites

  @doc """
  Get a site by name (or the default one)
  """
  def site_fixture(name \\ "default") do
    Sites.get_site!(name: name)
  end
end
