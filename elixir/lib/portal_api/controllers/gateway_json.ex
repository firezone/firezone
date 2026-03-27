defmodule PortalAPI.GatewayJSON do
  alias PortalAPI.Pagination
  alias Portal.Device

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

  defp data(%Device{} = device) do
    %{
      id: device.id,
      name: device.name,
      ipv4: device.ipv4,
      ipv6: device.ipv6,
      online: device.online?
    }
  end
end
