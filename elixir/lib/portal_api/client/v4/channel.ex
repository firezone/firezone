defmodule PortalAPI.Client.V4.Channel do
  @moduledoc """
  The v4 client control protocol: v3 plus metrics export. Clients on this channel
  receive a `metrics` config in `init` and `metrics_config` pushes.
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
  def protocol_version, do: 4

  @doc false
  def authorization_created_event, do: "authorization_created"

  @doc false
  def authorization_creation_failed_event, do: "authorization_creation_failed"
end
