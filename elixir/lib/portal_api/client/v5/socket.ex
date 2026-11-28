defmodule PortalAPI.Client.V5.Socket do
  @moduledoc """
  The `/client/v5` socket: the v4 client protocol over a plain WebSocket. See
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
      socket: PortalAPI.Client.Socket,
      channel: PortalAPI.Client.V5.Channel,
      topic: "client"
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
