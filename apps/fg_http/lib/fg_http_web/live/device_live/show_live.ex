defmodule FgHttpWeb.DeviceLive.Show do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.Devices

  @impl true
  def mount(params, session, socket) do
    {:ok, assign_defaults(params, session, socket, &load_data/2)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_device", %{"device_id" => device_id}, socket) do
    device = Devices.get_device!(device_id)

    if device.user_id == socket.assigns.current_user.id do
      case Devices.delete_device(device) do
        {:ok, _deleted_device} ->
          {:ok, _deleted_pubkey} = @events_module.delete_device(device.public_key)

          {:noreply,
           socket
           |> put_flash(:info, "Device deleted successfully.")
           |> redirect(to: Routes.device_index_path(socket, :index))}

          # Not likely to ever happen
          # {:error, msg} ->
          #   {:noreply,
          #   socket
          #   |> put_flash(:error, "Error deleting device: #{msg}")}
      end
    else
      {:noreply, not_authorized(socket)}
    end
  end

  defp load_data(%{"id" => id}, socket) do
    device = Devices.get_device!(id)

    if device.user_id == socket.assigns.current_user.id do
      assign(socket, device: device)
    else
      not_authorized(socket)
    end
  end
end
