defmodule PortalAPI.Channel.Protocol do
  @moduledoc """
  Pushes an event in the vocabulary of the socket's protocol.

  The shared channel code speaks `/client/v3`. A channel that speaks another protocol sets
  `channel_protocol` to a module that exports `encode/3`, which turns a `/client/v3` event and
  its payload into its own. `context` carries what an encoder needs beyond the payload.
  """

  @spec push(Phoenix.Socket.t(), String.t(), term(), term()) :: :ok
  def push(socket, event, payload, context \\ nil) do
    {event, payload} = encode(socket.assigns[:channel_protocol], event, payload, context)

    Phoenix.Channel.push(socket, event, payload)
  end

  defp encode(nil, event, payload, _context), do: {event, payload}

  defp encode(protocol, event, payload, context) do
    if function_exported?(protocol, :encode, 3) do
      protocol.encode(event, payload, context)
    else
      {event, payload}
    end
  end
end
