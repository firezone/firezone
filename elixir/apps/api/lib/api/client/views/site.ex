defmodule API.Client.Views.Site do
  alias Domain.Cache.Cacheable

  def render(%Cacheable.Site{} = site) do
    %{
      id: Ecto.UUID.load!(site.id),
      name: site.name
    }
  end
end
