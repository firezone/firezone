defmodule FgHttpWeb.NewDeviceLive do
  @moduledoc """
  Manages LiveView for New Devices
  """

  use Phoenix.LiveView
  use Phoenix.HTML
  alias FgHttp.Devices.Device
  alias FgHttpWeb.Router.Helpers, as: Routes

  def mount(_params, %{"user_id" => user_id}, socket) do
    if connected?(socket), do: wait_for_device_connect(socket)

    device = %Device{id: "1", user_id: user_id}
    {:ok, assign(socket, :device, device)}
  end

  # XXX: Receive other device details to create an intelligent name
  def handle_info({:pubkey, pubkey}, socket) do
    device = %Device{public_key: pubkey}
    {:noreply, assign(socket, :device, device)}
  end

  defp wait_for_device_connect(_socket) do
    :timer.send_after(3000, self(), {:pubkey, "foobar"})
  end
end
