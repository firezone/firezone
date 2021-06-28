defmodule CfHttpWeb.DeviceLive.FormComponent do
  @moduledoc """
  Handles device form.
  """
  use CfHttpWeb, :live_component

  alias CfHttp.Devices

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
      {:ok, _device} ->
        {:noreply,
         socket
         |> put_flash(:info, "Device updated successfully.")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
