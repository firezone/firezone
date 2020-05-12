defmodule FgHttpWeb.NewDeviceLive do
  use Phoenix.LiveView

  alias FgHttp.Devices.Device

  def mount(_params, %{"current_user_id" => user_id}, socket) do
    device = %Device{user_id: user_id}
    {:ok, assign(socket, :device, device)}
  end
end
