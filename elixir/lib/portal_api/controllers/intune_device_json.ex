defmodule PortalAPI.IntuneDeviceJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Intune.Device, PortalAPI.Schemas.IntuneDevice.Schema
  )

  alias Portal.Intune
  alias PortalAPI.Pagination

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%Intune.Device{} = device), do: PortalAPI.JSON.render(device, PortalAPI.Schemas.IntuneDevice.Schema)
end
