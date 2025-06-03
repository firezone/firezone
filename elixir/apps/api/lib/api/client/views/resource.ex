defmodule API.Client.Views.Resource do
  alias API.Client.Views
  alias Domain.Resources

  def render_many(resources) do
    Enum.map(resources, &render/1)
  end

  def render(%Resources.Resource{type: :internet} = resource) do
    %{
      id: resource.id,
      type: :internet,
      gateway_groups: Views.GatewayGroup.render_many(resource.gateway_groups),
      can_be_disabled: true,
      ip_stack: resource.ip_stack
    }
  end

  def render(%Resources.Resource{type: :ip} = resource) do
    {:ok, inet} = Domain.Types.IP.cast(resource.address)
    netmask = Domain.Types.CIDR.max_netmask(inet)
    address = to_string(%{inet | netmask: netmask})

    %{
      id: resource.id,
      type: :cidr,
      address: address,
      address_description: resource.address_description,
      name: resource.name,
      gateway_groups: Views.GatewayGroup.render_many(resource.gateway_groups),
      filters: Enum.flat_map(resource.filters, &render_filter/1),
      ip_stack: resource.ip_stack
    }
  end

  def render(%Resources.Resource{} = resource) do
    %{
      id: resource.id,
      type: resource.type,
      address: resource.address,
      address_description: resource.address_description,
      name: resource.name,
      gateway_groups: Views.GatewayGroup.render_many(resource.gateway_groups),
      filters: Enum.flat_map(resource.filters, &render_filter/1),
      ip_stack: resource.ip_stack
    }
  end

  def render_filter(%Resources.Resource.Filter{ports: ports} = filter) when length(ports) > 0 do
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

  def render_filter(%Resources.Resource.Filter{} = filter) do
    [
      %{
        protocol: filter.protocol
      }
    ]
  end

  defp port_to_number(port) do
    port |> String.trim() |> String.to_integer()
  end
end
