defmodule API.Client.Views.Resource do
  alias Domain.Resources

  def render_many(resources) do
    Enum.map(resources, &render/1)
  end

  def render(%Resources.Resource{type: :ip} = resource) do
    %{
      id: resource.id,
      type: :cidr,
      address: "#{resource.address}/32",
      name: resource.name
    }
  end

  def render(%Resources.Resource{} = resource) do
    %{
      id: resource.id,
      type: resource.type,
      address: resource.address,
      name: resource.name
    }
  end
end
