defmodule API.Client.Views.Resource do
  alias API.Client.Views
  alias Domain.Resources

  def render_many(resources) do
    Enum.map(resources, &render/1)
  end

  def render(%Resources.Resource{type: :ip} = resource) do
    {:ok, inet} = Domain.Types.IP.cast(resource.address)
    netmask = Domain.Types.CIDR.max_netmask(inet)
    address = to_string(%{inet | netmask: netmask})

    %{
      id: resource.id,
      type: :cidr,
      address: address,
      client_address: resource.client_address,
      name: resource.name,
      gateway_groups: Views.GatewayGroup.render_many(resource.gateway_groups)
    }
  end

  def render(%Resources.Resource{} = resource) do
    %{
      id: resource.id,
      type: resource.type,
      address: resource.address,
      client_address: resource.client_address,
      name: resource.name,
      gateway_groups: Views.GatewayGroup.render_many(resource.gateway_groups)
    }
  end
end
