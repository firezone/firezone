defmodule PortalAPI.Client.V2.Socket do
  use Phoenix.Socket

  channel "client", PortalAPI.Client.V2.Channel

  @impl true
  defdelegate connect(attrs, socket, connect_info), to: PortalAPI.Client.Socket

  @impl true
  defdelegate id(socket), to: PortalAPI.Client.Socket
end
