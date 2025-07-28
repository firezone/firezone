defmodule API.Client.Views.GatewayGroup do
  alias Domain.Cache.Cacheable

  def render_many(gateway_groups) do
    Enum.map(gateway_groups, &render/1)
  end

  def render(%Cacheable.GatewayGroup{} = gateway_group) do
    %{
      id: Ecto.UUID.load!(gateway_group.id),
      name: gateway_group.name
    }
  end
end
