defmodule PortalAPI.Gateway.V4.Socket do
  @moduledoc """
  The `/gateway/v4` socket: the newest gateway protocol over a plain WebSocket. See
  `PortalAPI.Sockets.Connection` for the framing.
  """
  @behaviour Phoenix.Socket.Transport

  alias PortalAPI.Sockets.Connection

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(transport_info) do
    Connection.connect(transport_info,
      handler: __MODULE__,
      socket: PortalAPI.Gateway.Socket,
      channel: PortalAPI.Gateway.V4.Channel,
      topic: "gateway"
    )
  end

  @impl true
  defdelegate init(state), to: Connection

  @impl true
  defdelegate handle_in(message, state), to: Connection

  @impl true
  defdelegate handle_info(message, state), to: Connection

  @impl true
  defdelegate terminate(reason, state), to: Connection

  @doc false
  def connections, do: Connection.connections(__MODULE__)
end
