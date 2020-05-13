defmodule FgHttpWeb.NewDeviceLive do
  use Phoenix.LiveView

  alias FgHttp.Devices.Device

  def mount(_params, %{"current_user_id" => user_id}, socket) do
    if connected?(socket), do: wait_for_device(socket)

    device = %Device{user_id: user_id}
    {:ok, assign(socket, :device, device)}
  end

  defp wait_for_device(socket) do
    # TODO: pass socket to fg_vpn somehow
    IO.inspect(socket)
    :timer.send_after(10000, self(), :update)
  end

  def handle_info(:update, socket) do
    new_device = Map.merge(socket.assigns.device, %{public_key: "foobar"})
    {:noreply, assign(socket, :device, new_device)}
  end
end
