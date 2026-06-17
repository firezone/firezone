defmodule PortalAPI.ResourceJSON do
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
    %{
      id: resource.id,
      name: resource.name,
      address: resource.address,
      address_description: resource.address_description,
      type: resource.type
    }
    |> maybe_put_ip_stack(resource)
    |> maybe_put_site_id(resource)
  end

  defp maybe_put_ip_stack(attrs, %{ip_stack: nil}) do
    attrs
  end

  defp maybe_put_ip_stack(attrs, resource) do
    Map.put(attrs, :ip_stack, resource.ip_stack)
  end

  defp maybe_put_site_id(attrs, %{site_id: nil}) do
    attrs
  end

  defp maybe_put_site_id(attrs, resource) do
    Map.put(attrs, :site_id, resource.site_id)
  end
end
