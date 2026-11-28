defmodule PortalAPI.Client.V5.Channel do
  @moduledoc """
  The `/client/v5` control protocol: v4 in its newest shape only. Only clients that speak the
  plain WebSocket protocol use it, so it adapts nothing to the client's version and takes none
  of the messages that clients before 1.4 send.
  """
  use PortalAPI, :channel
  alias PortalAPI.Client.Channel.Shared
  alias PortalAPI.Client.V4

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

  @impl true
  def join(topic, payload, socket) do
    socket
    |> assign(:channel_protocol, __MODULE__)
    |> then(&Shared.join(topic, payload, &1))
  end

  @impl true
  defdelegate terminate(reason, socket), to: Shared

  @impl true
  defdelegate handle_info(message, socket), to: V4.Channel

  @impl true
  def handle_in(event, payload, socket) when event in @events do
    Shared.handle_in(event, payload, socket)
  end

  def handle_in(event, payload, socket), do: Shared.unknown_message(event, payload, socket)

  @doc false
  def protocol_version, do: 5

  @doc false
  def authorization_created_event, do: "authorization_created"

  @doc false
  def authorization_creation_failed_event, do: "authorization_creation_failed"

  @doc false
  def encode("ice_candidates", payload, _context), do: {"gateway_ice_candidates", payload}

  def encode("invalidate_ice_candidates", payload, _context),
    do: {"invalidate_gateway_ice_candidates", payload}

  def encode(event, payload, _context), do: {event, payload}
end
