defmodule PortalAPI.Gateway.Views.Interface do
  alias Portal.Device

  def render(%Device{} = gateway) do
    %{
      ipv4: gateway.ipv4,
      ipv6: gateway.ipv6
    }
  end
end
