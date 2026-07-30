defmodule PortalAPI.Client.V3.Socket do
  use Phoenix.Socket

  ## Channels

  channel "client", PortalAPI.Client.V3.Channel

  # v3 defers device resolution on accounts with the device-trust gate
  # enabled: the channel resolves the device after the challenge round trip.
  @impl true
  def connect(attrs, socket, connect_info) do
    PortalAPI.Client.Socket.connect_deferring(attrs, socket, connect_info)
  end

  @impl true
  defdelegate id(socket), to: PortalAPI.Client.Socket
end
