defmodule PortalAPI.SantaDeviceJSON do
  use PortalAPI.JSON,
    struct: Portal.Santa.Device,
    schema: PortalAPI.Schemas.SantaDevice.Schema

  alias Portal.Santa
  alias PortalAPI.Pagination

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%Santa.Device{} = device), do: render_fields(device)
end
