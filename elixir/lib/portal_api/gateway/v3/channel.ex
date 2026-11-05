defmodule PortalAPI.Gateway.V3.Channel do
  @moduledoc """
  The v3 gateway control protocol: v2 plus metrics export. Gateways on this
  channel receive a `metrics` config in `init` and `metrics_config` pushes.
  """
  use PortalAPI, :channel
  alias PortalAPI.Gateway.Channel.Shared

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
  def create_authorization_event, do: "create_authorization"
end
