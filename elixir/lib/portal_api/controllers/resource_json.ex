defmodule PortalAPI.ResourceJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Resource, PortalAPI.Schemas.Resource.Schema,
    computed: [:filters],
    internal: [:account_id, :inserted_at, :updated_at]
  )

  alias PortalAPI.Pagination
  alias Portal.Resource

  @doc """
  Renders a list of resources.
  """
  def index(%{resources: resources, metadata: metadata}) do
    %{
      data: Enum.map(resources, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Renders a single resource.
  """
  def show(%{resource: resource}) do
    %{data: data(resource)}
  end

  defp data(%Resource{} = resource) do
    resource
    |> PortalAPI.JSON.render(PortalAPI.Schemas.Resource.Schema, %{
      filters: Enum.map(resource.filters, &filter/1)
    })
    |> PortalAPI.JSON.omit_nils([:ip_stack, :site_id])
  end

  defp filter(%Resource.Filter{} = filter) do
    %{
      protocol: filter.protocol,
      ports: filter.ports
    }
  end
end
