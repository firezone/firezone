defmodule PortalAPI.Gateway.V2.Socket do
  use Phoenix.Socket

  channel "gateway", PortalAPI.Gateway.V2.Channel

  @impl true
  defdelegate connect(attrs, socket, connect_info), to: PortalAPI.Gateway.Socket

  @impl true
  defdelegate id(socket), to: PortalAPI.Gateway.Socket
end
