defmodule PortalAPI.Gateway.V2.Channel do
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
  def create_authorization_event, do: "create_authorization"
end
