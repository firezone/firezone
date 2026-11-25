defmodule PortalAPI.Gateway.V3.Socket do
  use Phoenix.Socket

  channel "gateway", PortalAPI.Gateway.V3.Channel

  @impl true
  defdelegate connect(attrs, socket, connect_info), to: PortalAPI.Gateway.Socket

  @impl true
  defdelegate id(socket), to: PortalAPI.Gateway.Socket
end
