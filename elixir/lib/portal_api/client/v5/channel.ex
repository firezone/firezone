defmodule PortalAPI.Client.V5.Channel do
  @moduledoc """
  The v4 client protocol, without the messages that only clients before 1.4 send. Those
  expect a reply, and the plain WebSocket protocol has none.
  """
  alias PortalAPI.Client.Channel.Shared
  alias PortalAPI.Client.V4.Channel

  @events ~w[
    request_access
    resolve_device_domain
    browse_device_domain
    new_gateway_ice_candidates
    invalidate_gateway_ice_candidates
    new_client_ice_candidates
    invalidate_client_ice_candidates
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
