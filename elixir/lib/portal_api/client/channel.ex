defmodule PortalAPI.Client.Channel do
  @moduledoc """
  The v1 client protocol: an adapter over `PortalAPI.Device.Channel.Core`
  for clients that still call an authorization a flow.
  """
  use PortalAPI, :channel
  @behaviour PortalAPI.Device.Channel.Protocol

  alias PortalAPI.Device.Channel.Core

  defdelegate policy_authorization_queue_opts(), to: Core

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
  def handle_in("create_flow", payload, socket) do
    Core.handle_in("request_authorization", payload, socket)
  end

  def handle_in("request_authorization" = message, payload, socket) do
    Core.unknown(socket, message, payload)
  end

  def handle_in(message, payload, socket), do: Core.handle_in(message, payload, socket)

  @impl PortalAPI.Device.Channel.Protocol
  def protocol_version, do: 1

  @impl PortalAPI.Device.Channel.Protocol
  def kind, do: :client

  @impl PortalAPI.Device.Channel.Protocol
  def device_key, do: :client

  @impl PortalAPI.Device.Channel.Protocol
  def outbound?, do: true

  @impl PortalAPI.Device.Channel.Protocol
  def registration, do: :last_wins

  @impl PortalAPI.Device.Channel.Protocol
  def ack_mode, do: :auto

  @impl PortalAPI.Device.Channel.Protocol
  def create_authorization_event, do: "client_device_access_authorized"

  @impl PortalAPI.Device.Channel.Protocol
  def authorization_created_event, do: "flow_created"

  @impl PortalAPI.Device.Channel.Protocol
  def authorization_creation_failed_event, do: "flow_creation_failed"
end
