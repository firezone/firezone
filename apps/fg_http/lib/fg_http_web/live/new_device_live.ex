defmodule FgHttpWeb.NewDeviceLive do
  @moduledoc """
  Manages LiveView for New Devices
  """

  use Phoenix.LiveView
  use Phoenix.HTML
  alias FgHttp.{Devices.Device}
  alias FgHttpWeb.Router.Helpers, as: Routes
  alias Phoenix.PubSub

  @doc """
  Called when the view mounts. The for a device being added goes like follows:
  1. Present QR code to user
  2. User's device connects, :device_connected is received from the FgVpn application
  3. User confirms device, :verify_device message is broadcasted
  4. FgVpn receives :verify_device and adds the device to the config file
  """
  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    if connected?(socket) do
      # Subscribe to :device_connected events
      PubSub.subscribe(:fg_http_pub_sub, "view")
      # :timer.send_after(@mocked_timer, self(), {:pubkey, FgCrypto.rand_string()})
    end

    device = %Device{user_id: user_id}

    {:ok, assign(socket, :device, device)}
  end

  @doc """
  Handles device connect.
  """
  @impl true
  def handle_info({:device_connected, pubkey}, socket) do
    device = %{socket.assigns.device | public_key: pubkey, last_ip: "127.0.0.1"}

    # Updates @device in the LiveView and causes re-render
    {:noreply, assign(socket, :device, device)}
  end
end
