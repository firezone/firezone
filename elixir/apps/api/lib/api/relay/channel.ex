defmodule API.Relay.Channel do
  use API, :channel
  alias Domain.Relays

  @impl true
  def join("relay", %{"stamp_secret" => stamp_secret}, socket) do
    send(self(), {:after_join, stamp_secret})
    {:ok, socket}
  end

  @impl true
  def handle_info({:after_join, stamp_secret}, socket) do
    API.Endpoint.subscribe("relay:#{socket.assigns.relay.id}")
    push(socket, "init", %{})
    :ok = Relays.connect_relay(socket.assigns.relay, stamp_secret)
    {:noreply, socket}
  end
end
