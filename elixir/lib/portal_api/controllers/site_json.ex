defmodule PortalAPI.SiteJSON do
  alias PortalAPI.Pagination

  @doc """
  Renders a list of Sites.
  """
  def index(%{sites: sites, metadata: metadata}) do
    %{
      data: Enum.map(sites, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Site
  """
  def show(%{site: site}) do
    %{data: data(site)}
  end

  defp data(%Portal.Site{} = site) do
    %{
      id: site.id,
      name: site.name
    }
  end
end
