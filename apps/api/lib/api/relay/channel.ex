defmodule API.Relay.Channel do
  use API, :channel
  alias Domain.Relays.Presence

  @impl true
  def join("relay", %{"stamp_secret" => stamp_secret}, socket) do
    send(self(), {:after_join, stamp_secret})
    {:ok, socket}
  end

  @impl true
  def handle_info({:after_join, stamp_secret}, socket) do
    {:ok, _} =
      Presence.track(socket, socket.assigns.relay.id, %{
        online_at: System.system_time(:second),
        stamp_secret: stamp_secret
      })

    {:noreply, socket}
  end
end
