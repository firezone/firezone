defmodule PortalAPI.IntuneDeviceJSON do
  alias Portal.Intune
  alias PortalAPI.Pagination

  @fields Intune.Device.__schema__(:fields)

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%Intune.Device{} = device), do: Map.take(device, @fields)
end
