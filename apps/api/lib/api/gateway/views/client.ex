defmodule API.Gateway.Views.Device do
  alias Domain.Devices

  def render(%Devices.Device{} = device, device_rtc_session_description, preshared_key) do
    %{
      id: device.id,
      rtc_session_description: device_rtc_session_description,
      peer: %{
        persistent_keepalive: 25,
        public_key: device.public_key,
        preshared_key: preshared_key,
        ipv4: device.ipv4,
        ipv6: device.ipv6
      }
    }
  end
end
