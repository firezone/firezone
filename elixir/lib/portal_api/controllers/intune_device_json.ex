defmodule PortalAPI.IntuneDeviceJSON do
  use PortalAPI.JSON,
    struct: Portal.Intune.Device,
    schema: PortalAPI.Schemas.IntuneDevice.Schema

  alias Portal.Intune
  alias PortalAPI.Pagination

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%Intune.Device{} = device), do: render_fields(device)
end
