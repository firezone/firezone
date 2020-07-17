defmodule FgHttpWeb.NewDeviceLive do
  @moduledoc """
  Manages LiveView for New Devices
  """

  use Phoenix.LiveView
  use Phoenix.HTML
  alias FgHttp.{Devices.Device, Util.FgCrypto}
  alias FgHttpWeb.Router.Helpers, as: Routes

  # Number of seconds before simulating a device connect
  @mocked_timer 3000

  def mount(_params, %{"user_id" => user_id}, socket) do
    if connected?(socket) do
      # Send a mock device connect
      :timer.send_after(@mocked_timer, self(), {:pubkey, FgCrypto.rand_string()})
    end

    device = %Device{user_id: user_id, last_ip: "127.0.0.1"}

    {:ok, assign(socket, :device, device)}
  end

  # XXX: Receive other device details to create an intelligent name
  def handle_info({:pubkey, pubkey}, socket) do
    device = %{socket.assigns.device | public_key: pubkey}
    {:noreply, assign(socket, :device, device)}
  end
end
