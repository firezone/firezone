defmodule FzHttp.Sites do
  @moduledoc """
  The Sites context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.{Repo, Sites.Site}

  def get_site! do
    get_site!(name: "default")
  end

  def get_site!(name: name) do
    Repo.one!(
      from s in Site,
        where: s.name == ^name
    )
  end

  def get_site!(id) do
    Repo.get!(Site, id)
  end

  def change_site(%Site{} = site) do
    Site.changeset(site, %{})
  end

  def update_site(%Site{} = site, attrs) do
    site
    |> Site.changeset(attrs)
    |> Repo.update()
  end

  def vpn_sessions_expire? do
    freq = vpn_duration()
    freq > 0 && freq < Site.max_key_ttl()
  end

  def vpn_duration do
    get_site!().key_ttl
  end
end
