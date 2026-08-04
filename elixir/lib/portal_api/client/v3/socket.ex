defmodule PortalAPI.Client.V3.Socket do
  use Phoenix.Socket

  ## Channels

  # v3 speaks the v2 channel protocol verbatim. It exists to mark the clients
  # that can present an MDM-provisioned certificate over mutual TLS, which is
  # a connect-time concern only.
  channel "client", PortalAPI.Client.V2.Channel

  @impl true
  def connect(attrs, socket, connect_info) do
    PortalAPI.Client.Socket.connect_attesting(attrs, socket, connect_info)
  end

  @impl true
  defdelegate id(socket), to: PortalAPI.Client.Socket
end
