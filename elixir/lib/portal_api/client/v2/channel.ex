defmodule PortalAPI.Client.V2.Channel do
  @moduledoc """
  The v2 client protocol: an adapter over `PortalAPI.Device.Channel.Core`
  for clients that ask for authorizations by that name.
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
  def protocol_version, do: 2

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
  def authorization_created_event, do: "authorization_created"

  @impl PortalAPI.Device.Channel.Protocol
  def authorization_creation_failed_event, do: "authorization_creation_failed"
end
