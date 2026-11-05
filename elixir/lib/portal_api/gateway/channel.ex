defmodule PortalAPI.Gateway.Channel do
  use PortalAPI, :channel
  alias PortalAPI.Gateway.Channel.Shared

  defdelegate revoke_pair_access(gateway_id, client_id, resource_id), to: Shared

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
  def handle_in("flow_authorized", payload, socket) do
    Shared.handle_in("authorization_created", payload, socket)
  end

  def handle_in("authorization_created" = message, payload, socket) do
    Shared.unknown_message(message, payload, socket)
  end

  def handle_in(message, payload, socket) do
    Shared.handle_in(message, payload, socket)
  end

  @doc false
  def create_authorization_event, do: "authorize_flow"
end
