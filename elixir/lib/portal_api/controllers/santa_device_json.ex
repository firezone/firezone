defmodule PortalAPI.SantaDeviceJSON do
  alias Portal.Santa
  alias PortalAPI.Pagination

  @fields Santa.Device.__schema__(:fields)

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%Santa.Device{} = device), do: Map.take(device, @fields)
end
