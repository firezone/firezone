defmodule FzHttpWeb.Gateway.Channel do
  @moduledoc """
  Error handler for halting pipe processing when erroring out when communicating with the gateway
  """
  alias FzHttp.Gateways

  use FzHttpWeb, :channel

  @impl Phoenix.Channel
  def join("gateway:all", _payload, socket) do
    # XXX: Every gateway is expected to join here
    {:ok, socket}
  end

  @impl Phoenix.Channel
  def join("gateway:" <> id, _, socket) do
    # XXX: Here we check for Guardian.Phoenix.Socket.current_claims to check if the gateway has access to the channel
    send(self(), :after_join)

    {:ok, socket}
  end

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    gateway_config = Gateways.gateway_config(Gateways.get_gateway!())

    push(socket, "init", %{init: gateway_config})

    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_in("stats", stats, socket) do
    dbg(stats)
    {:noreply, socket}
  end
end
