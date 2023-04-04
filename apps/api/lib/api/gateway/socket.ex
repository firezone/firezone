defmodule API.Gateway.Socket do
  use Phoenix.Socket

  ## Channels

  channel "gateway:*", API.Gateway.Channel

  ## Authentication

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(socket), do: "gateway:#{socket.assigns.gateway.id}"
end
