defmodule PortalAPI.GatewayJSON do
  alias PortalAPI.Pagination

  @doc """
  Renders a list of Gateways.
  """
  def index(%{gateways: gateways, metadata: metadata}) do
    %{
      data: Enum.map(gateways, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Gateway
  """
  def show(%{gateway: gateway}) do
    %{data: data(gateway)}
  end

  defp data(%Portal.Gateway{} = gateway) do
    %{
      id: gateway.id,
      name: gateway.name,
      ipv4: gateway.ipv4_address.address,
      ipv6: gateway.ipv6_address.address,
      online: gateway.online?
    }
  end
end
