defmodule PortalAPI.Gateway.Channel do
  @moduledoc """
  The v1 gateway protocol: an adapter over `PortalAPI.Device.Channel.Core`
  for gateways that still call an authorization a flow. A meaningful share
  of active gateways are below 1.5.3 and still speak it.
  """
  use PortalAPI, :channel
  @behaviour PortalAPI.Device.Channel.Protocol

  alias PortalAPI.Device.Channel.Core

  defdelegate revoke_pair_access(gateway_id, client_id, resource_id), to: Core

  @impl Phoenix.Channel
  def join(topic, payload, socket) do
    socket
    |> assign(:channel_protocol, __MODULE__)
    |> then(&Core.join(topic, payload, &1))
  end

  @impl Phoenix.Channel
  defdelegate terminate(reason, socket), to: Core

  @impl Phoenix.Channel
  defdelegate handle_info(message, socket), to: Core

  @impl Phoenix.Channel
  def handle_in("flow_authorized", payload, socket) do
    Core.handle_in("authorization_created", payload, socket)
  end

  def handle_in("authorization_created" = message, payload, socket) do
    Core.unknown(socket, message, payload)
  end

  def handle_in(message, payload, socket), do: Core.handle_in(message, payload, socket)

  @impl PortalAPI.Device.Channel.Protocol
  def protocol_version, do: 1

  @impl PortalAPI.Device.Channel.Protocol
  def kind, do: :gateway

  @impl PortalAPI.Device.Channel.Protocol
  def device_key, do: :gateway

  @impl PortalAPI.Device.Channel.Protocol
  def outbound?, do: false

  @impl PortalAPI.Device.Channel.Protocol
  def registration, do: :first_wins

  @impl PortalAPI.Device.Channel.Protocol
  def ack_mode, do: :device_echo

  @impl PortalAPI.Device.Channel.Protocol
  def create_authorization_event, do: "authorize_flow"

  @impl PortalAPI.Device.Channel.Protocol
  def authorization_created_event, do: "flow_created"

  @impl PortalAPI.Device.Channel.Protocol
  def authorization_creation_failed_event, do: "flow_creation_failed"
end
