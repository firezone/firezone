defmodule FzHttpWeb.DeviceLive.FormComponent do
  @moduledoc """
  Handles device form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Devices

  def update(assigns, socket) do
    changeset = Devices.change_device(assigns.device)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  def handle_event("save", %{"device" => device_params}, socket) do
    device = socket.assigns.device

    case Devices.update_device(device, device_params) do
      {:ok, device} ->
        @events_module.device_updated(device)

        {:noreply,
         socket
         |> put_flash(:info, "Device updated successfully.")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
