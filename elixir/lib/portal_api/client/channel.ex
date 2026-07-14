defmodule PortalAPI.Client.Channel do
  use PortalAPI, :channel
  alias PortalAPI.Client.Channel.Shared

  defdelegate policy_authorization_queue_opts(), to: Shared

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
  def handle_in("create_flow", payload, socket) do
    Shared.handle_in("request_authorization", payload, socket)
  end

  def handle_in("request_authorization" = message, payload, socket) do
    Shared.unknown_message(message, payload, socket)
  end

  def handle_in(message, payload, socket) do
    Shared.handle_in(message, payload, socket)
  end

  @doc false
  def authorization_created_event, do: "flow_created"

  @doc false
  def authorization_creation_failed_event, do: "flow_creation_failed"
end
