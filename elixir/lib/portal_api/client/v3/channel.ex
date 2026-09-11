defmodule PortalAPI.Client.V3.Channel do
  @moduledoc """
  The v3 client control protocol: v2 plus device names. Clients on this channel
  resolve `<slug>.firezone.network` with `resolve_device_domain`, ask for access
  to a resolved device with `request_device_access`, and receive dynamic device
  pools in their resource list.
  """
  use PortalAPI, :channel
  alias PortalAPI.Client.Channel.Shared

  @impl true
  def join(topic, payload, socket) do
    socket
    |> assign(:channel_protocol, __MODULE__)
    |> then(&Shared.join(topic, payload, &1))
  end

  @impl true
  defdelegate terminate(reason, socket), to: Shared

  @impl true
  defdelegate handle_info(message, socket), to: Shared

  @impl true
  defdelegate handle_in(message, payload, socket), to: Shared

  @doc false
  def protocol_version, do: 3

  @doc false
  def authorization_created_event, do: "authorization_created"

  @doc false
  def authorization_creation_failed_event, do: "authorization_creation_failed"
end
