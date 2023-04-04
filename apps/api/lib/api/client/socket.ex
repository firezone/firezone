defmodule API.Client.Socket do
  use Phoenix.Socket

  ## Channels

  channel "client:*", API.Client.Channel

  ## Authentication

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(socket), do: "client:#{socket.assigns.client.id}"
end
