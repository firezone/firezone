defmodule API.Gateway.Views.Interface do
  alias Domain.Gateway

  def render(%Gateway{} = gateway) do
    %{
      ipv4: gateway.ipv4,
      ipv6: gateway.ipv6
    }
  end
end
