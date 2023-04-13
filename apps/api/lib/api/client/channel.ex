defmodule API.Client.Channel do
  use API, :channel
  alias Domain.Clients

  # TODO: we need to self-terminate channel once the user token is set to expire, preventing
  # users from holding infinite session for if they want to keep websocket open for a while

  @impl true
  def join("client", _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    :ok = Clients.connect_client(socket.assigns.client, socket)
    :ok = push(socket, "resources", %{resources: []})
    {:noreply, socket}
  end
end
