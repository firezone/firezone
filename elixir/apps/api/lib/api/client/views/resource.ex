defmodule API.Client.Views.Resource do
  alias API.Client.Views
  alias Domain.Cache.Cacheable

  def render_many(resources) do
    Enum.map(resources, &render/1)
  end

  def render(%Cacheable.Resource{} = resource) do
    resource
    |> Map.from_struct()
    |> Map.put(:id, Ecto.UUID.load!(resource.id))
    |> render_resource()
  end

  defp render_resource(%{type: :internet} = resource) do
    %{
      id: resource.id,
      type: :internet,
      # TODO: conditionally rename to sites based on client version
      # apple: >= 1.5.11
      # headless: >= 1.5.6
      # android: >= 1.5.8
      # gui: >= 1.5.10
      # See https://github.com/firezone/firezone/commit/9d8b55212aea418264a272109776e795f5eda6ce
      gateway_groups: [Views.Site.render(resource.site)],
      can_be_disabled: true
    }
  end

  defp render_resource(%{type: :ip} = resource) do
    {:ok, inet} = Domain.Types.IP.cast(resource.address)
    netmask = Domain.Types.CIDR.max_netmask(inet)
    address = to_string(%{inet | netmask: netmask})

    %{
      id: resource.id,
      type: :cidr,
      address: address,
      address_description: resource.address_description,
      name: resource.name,
      # TODO: conditionally rename to sites based on client version
      # apple: >= 1.5.11
      # headless: >= 1.5.6
      # android: >= 1.5.8
      # gui: >= 1.5.10
      # See https://github.com/firezone/firezone/commit/9d8b55212aea418264a272109776e795f5eda6ce
      gateway_groups: [Views.Site.render(resource.site)],
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
  end

  defp render_resource(%{} = resource) do
    %{
      id: resource.id,
      type: resource.type,
      address: resource.address,
      address_description: resource.address_description,
      name: resource.name,
      # TODO: conditionally rename to sites based on client version
      # apple: >= 1.5.11
      # headless: >= 1.5.6
      # android: >= 1.5.8
      # gui: >= 1.5.10
      # See https://github.com/firezone/firezone/commit/9d8b55212aea418264a272109776e795f5eda6ce
      gateway_groups: [Views.Site.render(resource.site)],
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
    |> maybe_put_ip_stack(resource)
  end

  defp render_filter(%{ports: ports} = filter) when ports != [] do
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

  defp render_filter(%{} = filter) do
    [
      %{
        protocol: filter.protocol
      }
    ]
  end

  defp port_to_number(port) do
    port |> String.trim() |> String.to_integer()
  end

  defp maybe_put_ip_stack(attrs, %{ip_stack: nil}) do
    attrs
  end

  defp maybe_put_ip_stack(attrs, resource) do
    Map.put(attrs, :ip_stack, resource.ip_stack)
  end
end
