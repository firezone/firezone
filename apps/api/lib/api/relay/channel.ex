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
    :ok = Relays.connect_relay(socket.assigns.relay, stamp_secret, socket)
    {:noreply, socket}
  end

  # def handle_in("metrics", %{"metrics" => metrics}, socket) do
  #   metrics = %{
  #     "cpu" => 0.1,
  #     "memory" => 0.2,
  #     "disk" => 0.3,
  #     "rx" => 120,
  #     "tx" => 100,
  #     "connections" => 57
  #   }

  #   :ok = Relays.update_metrics(socket.assigns.relay, metrics)
  #   {:noreply, socket}
  # end
end
