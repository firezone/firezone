defmodule PortalAPI.Gateway.V4.Channel do
  @moduledoc """
  The `/gateway/v4` control protocol: v3 in its newest shape only. Only gateways that speak the
  plain WebSocket protocol use it, so it adapts nothing to the gateway's version and has none
  of the messages that clients before 1.4 need.
  """
  use PortalAPI, :channel
  alias PortalAPI.Gateway.Channel.Shared
  alias PortalAPI.Gateway.V3

  @events ~w[
    authorization_created
    broadcast_ice_candidates
    broadcast_invalidated_ice_candidates
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
  def handle_info({request, _from, _attrs}, socket) when request in [:allow_access, :request_connection] do
    {:noreply, socket}
  end

  def handle_info(message, socket), do: V3.Channel.handle_info(message, socket)

  @impl true
  def handle_in(event, payload, socket) when event in @events do
    Shared.handle_in(event, payload, socket)
  end

  def handle_in(event, payload, socket), do: Shared.unknown_message(event, payload, socket)

  @doc false
  def protocol_version, do: 4

  @doc false
  def create_authorization_event, do: "create_authorization"
end
