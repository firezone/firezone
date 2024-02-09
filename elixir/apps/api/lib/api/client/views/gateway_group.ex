defmodule API.Client.Views.GatewayGroup do
  alias Domain.Gateways

  def render_many(gateway_groups) do
    Enum.map(gateway_groups, &render/1)
  end

  def render(%Gateways.Group{} = gateway_group) do
    %{
      id: gateway_group.id,
      name: gateway_group.name,
      routing: gateway_group.routing
    }
  end
end
