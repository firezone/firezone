defmodule FzHttpWeb.DeviceLive.Unprivileged.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.Devices

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id

    {:ok,
     socket
     |> assign(:devices, Devices.list_devices(user_id))
     |> assign(:page_title, "WireGuard Tunnels")}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_device", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    device = Devices.get_device!(id)

    case delete_device(device, socket) do
      {:not_authorized} ->
        {:noreply, not_authorized(socket)}

      {:ok, _device} ->
        {:noreply,
         socket
         |> assign(:devices, Devices.list_devices(user_id))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not delete device.")}
    end
  end

  defp delete_device(device, socket) do
    if device.user_id == socket.assigns.current_user.id do
      Devices.delete_device(device)
    else
      {:not_authorized}
    end
  end

  @doc """
  This is called when modal is closed. Conveniently, allows us to reload
  devices table.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    user_id = socket.assigns.current_user.id

    {:noreply,
     socket
     |> assign(:devices, Devices.list_devices(user_id))}
  end
end
