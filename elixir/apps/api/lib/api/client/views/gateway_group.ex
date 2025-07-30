defmodule API.Client.Views.GatewayGroup do
  alias Domain.Clients.Cache

  def render_many(gateway_groups) do
    Enum.map(gateway_groups, &render/1)
  end

  def render(%Cache.GatewayGroup{} = gateway_group) do
    %{
      id: Ecto.UUID.load!(gateway_group.id),
      name: gateway_group.name
    }
  end
end
