defmodule API.Gateway.Views.Resource do
  alias Domain.Resources

  def render(%Resources.Resource{type: :dns} = resource) do
    %{
      id: resource.id,
      type: :dns,
      address: resource.address,
      name: resource.name,
      ipv4: resource.ipv4,
      ipv6: resource.ipv6,
      filters: Enum.map(resource.filters, &render_filter/1)
    }
  end

  def render(%Resources.Resource{type: :cidr} = resource) do
    %{
      id: resource.id,
      type: :cidr,
      address: resource.address,
      name: resource.name,
      filters: Enum.map(resource.filters, &render_filter/1)
    }
  end

  def render_filter(%Resources.Resource.Filter{} = filter) do
    %{
      protocol: filter.protocol,
      ports: filter.ports
    }
  end
end
