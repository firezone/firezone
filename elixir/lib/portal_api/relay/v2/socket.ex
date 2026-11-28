defmodule PortalAPI.Relay.V2.Socket do
  @moduledoc """
  The `/relay/v2` socket: the relay protocol over a plain WebSocket. See
  `PortalAPI.Sockets.Connection` for the framing.

  The relay sends its stamp secret in the `X-Stamp-Secret` header, as there is no join
  message. TURN account validation is always on.
  """
  @behaviour Phoenix.Socket.Transport

  alias PortalAPI.Sockets.Connection

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(transport_info) do
    Connection.connect(transport_info,
      handler: __MODULE__,
      socket: PortalAPI.Relay.Socket,
      channel: PortalAPI.Relay.Channel,
      topic: "relay",
      join_payload: &join_payload/1
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

  defp join_payload(%{x_headers: x_headers}) do
    case List.keyfind(x_headers, "x-stamp-secret", 0) do
      {_name, stamp_secret} when byte_size(stamp_secret) in 1..256 ->
        {:ok, %{"stamp_secret" => stamp_secret, "turn_account_validation" => true}}

      _other ->
        {:error, :invalid_stamp_secret}
    end
  end
end
