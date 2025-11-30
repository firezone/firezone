defmodule API.Client.Views.Site do
  alias Domain.Cache.Cacheable

  def render_many(sites) do
    Enum.map(sites, &render/1)
  end

  def render(%Cacheable.Site{} = site) do
    %{
      id: Ecto.UUID.load!(site.id),
      name: site.name
    }
  end
end
