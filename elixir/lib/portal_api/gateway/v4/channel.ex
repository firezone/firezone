defmodule PortalAPI.Gateway.V4.Channel do
  @moduledoc """
  The v3 gateway protocol, without the messages that answer clients before 1.4. Those
  expect a reply, and the plain WebSocket protocol has none.
  """
  alias PortalAPI.Gateway.Channel.Shared
  alias PortalAPI.Gateway.V3.Channel

  @events ~w[
    authorization_created
    broadcast_ice_candidates
    broadcast_invalidated_ice_candidates
    set_snownet_capabilities
    no_relays
  ]

  defdelegate join(topic, payload, socket), to: Channel
  defdelegate terminate(reason, socket), to: Channel
  defdelegate handle_info(message, socket), to: Channel

  def handle_in(event, payload, socket) when event in @events do
    Channel.handle_in(event, payload, socket)
  end

  def handle_in(event, payload, socket), do: Shared.unknown_message(event, payload, socket)
end
