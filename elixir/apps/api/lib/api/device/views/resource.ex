defmodule API.Device.Views.Resource do
  alias Domain.Resources

  def render_many(resources) do
    Enum.map(resources, &render/1)
  end

  def render(%Resources.Resource{} = resource) do
    %{
      id: resource.id,
      address: resource.address,
      ipv4: resource.ipv4,
      ipv6: resource.ipv6
    }
  end
end
