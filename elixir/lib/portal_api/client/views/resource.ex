defmodule PortalAPI.Client.Views.Resource do
  alias PortalAPI.Client.Views
  alias Portal.Cache.Cacheable

  def render_many(resources, client_session, protocol_version) do
    site_key = site_key(client_session)

    Enum.map(resources, &render_cacheable(&1, site_key, protocol_version))
  end

  def render(%Cacheable.Resource{} = resource, client_session, protocol_version) do
    render_cacheable(resource, site_key(client_session), protocol_version)
  end

  @doc """
    Renders the minimal `{id, filters}` view used in `client_device_access_authorized` and
    `resource_filters_updated` payloads, where the receiving client only needs to know
    which resource was authorized and what its filters look like.
  """
  def render_authorization(%Cacheable.Resource{} = resource) do
    %{
      id: Ecto.UUID.load!(resource.id),
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
  end

  defp render_cacheable(%Cacheable.Resource{} = resource, site_key, protocol_version) do
    resource
    |> Map.from_struct()
    |> Map.put(:id, Ecto.UUID.load!(resource.id))
    |> put_wire_pool_type(protocol_version)
    |> render_resource(site_key)
  end

  # The v2 protocol knows a listed pool as `static_device_pool` with its members inline
  # and an own-devices pool as `dynamic_device_pool` with the device domain as its pattern.
  defp put_wire_pool_type(%{type: :device_pool} = resource, protocol_version)
       when protocol_version < 3 do
    case Portal.Resource.DeviceMembershipCriteria.device_ids(resource.device_membership_criteria) do
      {:ok, _device_ids} -> %{resource | type: :static_device_pool}
      :error -> %{resource | type: :dynamic_device_pool}
    end
  end

  defp put_wire_pool_type(resource, _protocol_version), do: resource

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

  defp render_resource(%{type: :static_device_pool} = resource, _site_key) do
    %{
      id: resource.id,
      type: :static_device_pool,
      name: resource.name,
      devices: render_devices(resource.devices),
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
  end

  defp render_resource(%{type: :dynamic_device_pool} = resource, _site_key) do
    %{
      id: resource.id,
      type: :dynamic_device_pool,
      name: resource.name,
      address: "*.#{Portal.Device.domain()}",
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
  end

  defp render_resource(%{type: :device_pool} = resource, _site_key) do
    %{
      id: resource.id,
      type: :device_pool,
      name: resource.name,
      members: resource.members,
      filters: Enum.flat_map(resource.filters, &render_filter/1)
    }
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

  defp render_devices(nil), do: []

  defp render_devices(devices) do
    Enum.map(devices, fn %{id: id, ipv4: ipv4, ipv6: ipv6} ->
      %{client_id: id, ipv4: ipv4, ipv6: ipv6}
    end)
  end
end
