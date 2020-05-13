defmodule FgHttpWeb.NewDeviceLive do
  use Phoenix.LiveView
  use Phoenix.HTML
  alias FgHttpWeb.Router.Helpers, as: Routes

  alias FgHttp.Devices.Device

  def mount(_params, %{}, socket) do
    user_id = "1"
    IO.inspect(socket)
    if connected?(socket), do: wait_for_device(socket)

    device = %Device{id: "1", user_id: user_id}
    {:ok, assign(socket, :device, device)}
  end

  defp wait_for_device(socket) do
    # TODO: pass socket to fg_vpn somehow
    IO.inspect(socket)
    :timer.send_after(3000, self(), :update)
  end

  def handle_info(:update, socket) do
    new_device = Map.merge(socket.assigns.device, %{public_key: "foobar"})
    {:noreply, assign(socket, :device, new_device)}
  end
end
