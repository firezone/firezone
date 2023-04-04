defmodule API.Relay.Socket do
  use Phoenix.Socket

  ## Channels

  channel "relay:*", API.Relay.Channel

  ## Authentication

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(socket), do: "relay:#{socket.assigns.relay.id}"
end
