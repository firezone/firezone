defmodule PortalAPI.Device.Socket do
  @moduledoc """
  The `/device/v1` socket, for the binary that both reaches and serves resources.

  A device connects with the same credentials as on the client socket. It also states the
  range of protocol minors it speaks, as `proto_min` and `proto_max`.
  """
  use Phoenix.Socket

  channel "device", PortalAPI.Device.V1.Channel

  @impl true
  def connect(attrs, socket, connect_info) do
    with {:ok, socket} <- PortalAPI.Client.Socket.connect(attrs, socket, connect_info),
         {:ok, proto_range} <- proto_range(attrs) do
      {:ok, assign(socket, :proto_range, proto_range)}
    end
  end

  @impl true
  defdelegate id(socket), to: PortalAPI.Client.Socket

  defp proto_range(attrs) do
    case Portal.Version.declared_proto_range(attrs) do
      nil -> {:error, :invalid_proto_range}
      range -> {:ok, range}
    end
  end
end
