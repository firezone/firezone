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
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("delete_device", %{"device_id" => device_id}, socket) do
    # XXX: Authorization
    device = Devices.get_device!(device_id)

    case Devices.delete_device(device) do
      {:ok, _deleted_device} ->
        {:ok, _deleted_pubkey} = @events_module.delete_device(device.public_key)

        {:noreply,
         socket
         |> put_flash(:info, "Device deleted successfully.")
         |> redirect(to: Routes.device_index_path(socket, :index))}

      {:error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error deleting device: #{msg}")}
    end
  end

  defp apply_action(socket, :edit, _params) do
    socket
  end

  defp apply_action(socket, :show, _params) do
    socket
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
