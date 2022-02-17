defmodule FzHttpWeb.DeviceLive.Admin.UpdateFormComponent do
  @moduledoc """
  Handles device form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.{Devices, Sites}

  def update(assigns, socket) do
    device = assigns.device
    changeset = Devices.change_device(device)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(Devices.defaults(changeset))
     |> assign(Sites.wireguard_defaults())
     |> assign(:changeset, changeset)}
  end

  def handle_event("change", %{"device" => device_params}, socket) do
    changeset = Devices.change_device(socket.assigns.device, device_params)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(Devices.defaults(changeset))}
  end

  def handle_event("save", %{"device" => device_params}, socket) do
    device = socket.assigns.device

    case Devices.update_device(device, device_params) do
      {:ok, device} ->
        @events_module.update_device(device)

        {:noreply,
         socket
         |> put_flash(:info, "Device updated successfully.")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
