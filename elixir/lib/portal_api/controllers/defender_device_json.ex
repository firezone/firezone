defmodule PortalAPI.DefenderDeviceJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Defender.Device, PortalAPI.Schemas.DefenderDevice.Schema
  )

  alias Portal.Defender
  alias PortalAPI.Pagination

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%Defender.Device{} = device), do: PortalAPI.JSON.render(device, PortalAPI.Schemas.DefenderDevice.Schema)
end
