defmodule PortalAPI.DefenderDeviceJSON do
  use PortalAPI.JSON,
    struct: Portal.Defender.Device,
    schema: PortalAPI.Schemas.DefenderDevice.Schema

  alias Portal.Defender
  alias PortalAPI.Pagination

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%Defender.Device{} = device), do: render_fields(device)
end
