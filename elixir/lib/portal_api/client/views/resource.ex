defmodule PortalAPI.Client.Views.Resource do
  alias PortalAPI.Client.Views
  alias Portal.Cache.Cacheable

  def render_many(resources, client_session \\ nil) do
    site_key = site_key(client_session)

    Enum.map(resources, &render_cacheable(&1, site_key))
  end

  def render(%Cacheable.Resource{} = resource, client_session \\ nil) do
    render_cacheable(resource, site_key(client_session))
  end

  defp render_cacheable(%Cacheable.Resource{} = resource, site_key) do
    resource
    |> Map.from_struct()
    |> Map.put(:id, Ecto.UUID.load!(resource.id))
    |> render_resource(site_key)
  end

  defp render_resource(%{type: :internet} = resource, site_key) do
    %{
      id: resource.id,
      type: :internet,
      can_be_disabled: true
    }
    |> put_sites([Views.Site.render(resource.site)], site_key)
  end

  defp render_resource(%{type: :ip} = resource, site_key) do
    {:ok, inet} = Portal.Types.IP.cast(resource.address)
    netmask = Portal.Types.CIDR.max_netmask(inet)
    address = to_string(%{inet | netmask: netmask})

    %{
      id: resource.id,
      type: :cidr,
      address: address,
      address_description: resource.address_description,
      name: resource.name,
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
    |> put_sites([Views.Site.render(resource.site)], site_key)
  end

  defp render_resource(%{type: :static_device_pool} = resource, site_key) do
    %{
      id: resource.id,
      type: :static_device_pool,
      name: resource.name,
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
    |> put_sites([], site_key)
  end

  defp render_resource(%{} = resource, site_key) do
    %{
      id: resource.id,
      type: resource.type,
      address: resource.address,
      address_description: resource.address_description,
      name: resource.name,
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
    |> put_sites([Views.Site.render(resource.site)], site_key)
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

  defp site_key(client_session) do
    if Portal.Version.client_supports_sites_payload?(client_session) do
      :sites
    else
      :gateway_groups
    end
  end

  defp put_sites(attrs, sites, site_key) do
    Map.put(attrs, site_key, sites)
  end
end
