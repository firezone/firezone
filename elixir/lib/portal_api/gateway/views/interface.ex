defmodule PortalAPI.Gateway.Views.Interface do
  alias Portal.Gateway

  def render(%Gateway{} = gateway) do
    %{
      ipv4: gateway.ipv4_address.address,
      ipv6: gateway.ipv6_address.address
    }
  end
end
