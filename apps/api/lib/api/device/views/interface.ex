defmodule API.Device.Views.Interface do
  alias Domain.Devices

  def render(%Devices.Device{} = device) do
    upstream_dns =
      Devices.fetch_device_config!(device)
      |> Keyword.fetch!(:upstream_dns)

    %{
      upstream_dns: upstream_dns,
      ipv4: device.ipv4,
      ipv6: device.ipv6
    }
  end
end
