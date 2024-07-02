defmodule API.ResourceJSON do
  alias Domain.Resources.Resource
  alias Domain.Repo.Paginator.Metadata

  @doc """
  Renders a list of resources.
  """
  def index(%{resources: resources, metadata: metadata}) do
    %{data: for(resource <- resources, do: data(resource))}
    |> Map.put(:metadata, metadata(metadata))
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
      description: resource.address_description,
      type: resource.type
    }
  end

  defp metadata(%Metadata{} = metadata) do
    %{
      count: metadata.count,
      limit: metadata.limit,
      next_page: metadata.next_page_cursor,
      prev_page: metadata.previous_page_cursor
    }
  end
end
