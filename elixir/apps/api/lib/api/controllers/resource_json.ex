defmodule API.ResourceJSON do
  alias API.Pagination
  alias Domain.Resources.Resource

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
  end
end
