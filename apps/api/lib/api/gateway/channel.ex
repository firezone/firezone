defmodule API.Gateway.Channel do
  use API, :channel
  alias Domain.Gateways

  @impl true
  def join("gateway", _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    Gateways.connect_gateway(socket.assigns.gateway, socket)
    {:noreply, socket}
  end
end
