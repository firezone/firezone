defmodule API.Gateway.Views.Resource do
  alias Domain.Resources

  def render(%Resources.Resource{type: :dns} = resource) do
    %{
      id: resource.id,
      type: :dns,
      address: resource.address,
      name: resource.name,
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
  end

  def render(%Resources.Resource{type: :cidr} = resource) do
    %{
      id: resource.id,
      type: :cidr,
      address: resource.address,
      name: resource.name,
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
  end

  def render(%Resources.Resource{type: :ip} = resource) do
    %{
      id: resource.id,
      type: :cidr,
      address: "#{resource.address}/32",
      name: resource.name,
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
  end

  def render_filter(%Resources.Resource.Filter{} = filter) do
    Enum.map(filter.ports, fn port ->
      case String.split(port, "-") do
        [port_start, port_end] ->
          port_start = port_to_number(port_start)
          port_end = port_to_number(port_end)

          %{
            protocol: filter.protocol,
            port_range_start: port_start,
            port_range_end: port_end
          }

        [port] ->
          port = port_to_number(port)

          %{
            protocol: filter.protocol,
            port_range_start: port,
            port_range_end: port
          }
      end
    end)
  end

  defp port_to_number(port) do
    port |> String.trim() |> String.to_integer()
  end
end
