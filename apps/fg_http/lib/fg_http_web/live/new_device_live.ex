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
  1. :add_device is broadcasted
  2. FgVpn picks this up and creates a new peer, adds to config, broadcasts :peer_added
  3. :peer_added is handled here which confirms the details to the user
  4. User confirms device, clicks create
  # XXX: Add ttl to device creation that removes stale devices
  """
  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    if connected?(socket) do
      # Subscribe to :device_connected events
      PubSub.subscribe(:fg_http_pub_sub, "view")
    end

    # Fire off event to generate private key, psk, and add device to config
    PubSub.broadcast(:fg_http_pub_sub, "config", {:add_device, self()})

    device = %Device{user_id: user_id}

    {:ok, assign(socket, :device, device)}
  end

  @doc """
  Handles device added.
  """
  @impl true
  def handle_info({:peer_added, caller_pid, privkey, pubkey, server_pubkey}, socket) do
    if caller_pid == self() do
      device = %{
        socket.assigns.device
        | public_key: pubkey,
          private_key: privkey,
          server_pubkey: server_pubkey,
          last_ip: "127.0.0.1",
          name: "Device #{pubkey}"
      }

      # Updates @device in the LiveView and causes re-render if the intended target is this pid
      {:noreply, assign(socket, :device, device)}
    else
      # Noop, let the correct pid handle this broadcast
      {:noreply, socket}
    end
  end
end
