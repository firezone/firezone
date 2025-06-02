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
    |> maybe_put_ip_stack(resource)
  end

  defp maybe_put_ip_stack(attrs, %{type: :dns} = resource) do
    if resource.ip_stack do
      Map.put(attrs, :ip_stack, resource.ip_stack)
    else
      attrs
    end
  end

  defp maybe_put_ip_stack(attrs, _resource) do
    attrs
  end
end
