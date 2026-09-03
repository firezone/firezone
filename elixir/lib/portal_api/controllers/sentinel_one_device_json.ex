defmodule PortalAPI.SentinelOneDeviceJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.SentinelOne.Device, PortalAPI.Schemas.SentinelOneDevice.Schema,
    # The endpoint license key is credential-like and never published.
    internal: [:license_key]
  )

  alias Portal.SentinelOne
  alias PortalAPI.Pagination

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%SentinelOne.Device{} = device), do: PortalAPI.JSON.render(device, PortalAPI.Schemas.SentinelOneDevice.Schema)
end
