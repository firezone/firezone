defmodule PortalAPI.IruDeviceJSON do
  use PortalAPI.JSON,
    struct: Portal.Iru.Device,
    schema: PortalAPI.Schemas.IruDevice.Schema

  alias Portal.Iru
  alias PortalAPI.Pagination

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%Iru.Device{} = device), do: render_fields(device)
end
