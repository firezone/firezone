defmodule FgHttpWeb.NewDeviceLive do
  use Phoenix.LiveView

  alias FgHttp.Devices

  def render(assigns) do
    ~L"""
      [Peer]
      PublicKey = <%= assigns.device.public_key %>
      AllowedIPs = 0.0.0.0/0, ::/0
      Endpoint = <%= Application.fetch_env!(:fg_http, :vpn_endpoint) %>
    """
  end

  def mount(_params, %{"current_user_id" => user_id}, socket) do
    device = Devices.new_device(%{user_id: user_id})
    {:ok, assign(socket, :device, device)}
  end
end
