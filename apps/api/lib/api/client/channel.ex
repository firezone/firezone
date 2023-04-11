defmodule API.Client.Channel do
  use API, :channel
  alias API.Client.Presence

  # TODO: we need to self-terminate channel once the user token is set to expire, preventing
  # users from holding infinite session for if they want to keep websocket open for a while

  @impl true
  def join("client", _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _} =
      Presence.track(socket, socket.assigns.client.id, %{
        online_at: System.system_time(:second)
      })

    :ok = push(socket, "resources", %{resources: []})

    {:noreply, socket}
  end
end
