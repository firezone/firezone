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
      online: device.online?,
      public_key: device.public_key,
      last_seen_at: device.last_seen_at,
      last_seen_version: device.last_seen_version,
      last_seen_user_agent: device.last_seen_user_agent,
      last_seen_remote_ip: device.last_seen_remote_ip,
      last_seen_remote_ip_location_region: device.last_seen_remote_ip_location_region,
      last_seen_remote_ip_location_city: device.last_seen_remote_ip_location_city,
      last_seen_remote_ip_location_lat: device.last_seen_remote_ip_location_lat,
      last_seen_remote_ip_location_lon: device.last_seen_remote_ip_location_lon
    }
  end
end
