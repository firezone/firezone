defmodule API.Gateway.Views.Interface do
  alias Domain.Gateways

  def render(%Gateways.Gateway{} = gateway) do
    %{
      ipv4: gateway.ipv4,
      ipv6: gateway.ipv6
    }
  end
end
