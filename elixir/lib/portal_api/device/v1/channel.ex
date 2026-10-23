defmodule PortalAPI.Device.V1.Channel do
  @moduledoc """
  The `/device/v1` protocol: the union of what clients and gateways speak,
  on one socket, as an adapter over `PortalAPI.Device.Channel.Core`.

  Init carries the outbound view, `resources` the device may reach, and the
  inbound view: `sites_served`, `local_resources`, every resource served by
  those sites, and `authorizations` where the device is the receiver.
  `local_resource_created_or_updated` and `local_resource_deleted` keep that
  list current. `create_authorization` names the device's `ice_role` and a
  `target` of a resource or of the device itself through a pool; the device
  echoes the signed `ref` once the authorization is installed, whichever the
  target. ICE candidates are keyed by `device_id` in both directions, and
  `set_capabilities` tells the portal what the device can do. A second
  connection for the same device supersedes the first.
  """
  use PortalAPI, :channel
  @behaviour PortalAPI.Device.Channel.Protocol

  alias PortalAPI.Device.Channel.Core

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
  defdelegate handle_in(message, payload, socket), to: Core

  @impl PortalAPI.Device.Channel.Protocol
  def protocol_version, do: 4

  @impl PortalAPI.Device.Channel.Protocol
  def kind, do: :device

  @impl PortalAPI.Device.Channel.Protocol
  def device_key, do: :device

  @impl PortalAPI.Device.Channel.Protocol
  def outbound?, do: true

  @impl PortalAPI.Device.Channel.Protocol
  def registration, do: :last_wins

  @impl PortalAPI.Device.Channel.Protocol
  def ack_mode, do: :device_echo

  @impl PortalAPI.Device.Channel.Protocol
  def create_authorization_event, do: "create_authorization"

  @impl PortalAPI.Device.Channel.Protocol
  def authorization_created_event, do: "authorization_created"

  @impl PortalAPI.Device.Channel.Protocol
  def authorization_creation_failed_event, do: "authorization_creation_failed"
end
