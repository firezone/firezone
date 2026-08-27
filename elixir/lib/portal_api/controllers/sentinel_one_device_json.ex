defmodule PortalAPI.SentinelOneDeviceJSON do
  alias Portal.SentinelOne
  alias PortalAPI.Pagination

  # The endpoint license key is inventory data in SentinelOne's source schema,
  # but it is credential-like and therefore never returned from Firezone's API.
  @fields SentinelOne.Device.__schema__(:fields) -- [:license_key]

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%SentinelOne.Device{} = device), do: Map.take(device, @fields)
end
