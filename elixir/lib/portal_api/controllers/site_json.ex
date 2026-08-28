defmodule PortalAPI.SiteJSON do
  use PortalAPI.JSON,
    struct: Portal.Site,
    schema: PortalAPI.Schemas.Site.Schema,
    internal: [:account_id, :health_threshold, :inserted_at, :managed_by, :updated_at]

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

  defp data(%Portal.Site{} = site), do: render_fields(site)
end
