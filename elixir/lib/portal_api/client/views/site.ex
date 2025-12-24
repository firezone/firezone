defmodule PortalAPI.Client.Views.Site do
  alias Portal.Cache.Cacheable

  def render(%Cacheable.Site{} = site) do
    %{
      id: Ecto.UUID.load!(site.id),
      name: site.name
    }
  end
end
