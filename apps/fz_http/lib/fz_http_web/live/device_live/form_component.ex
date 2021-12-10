defmodule FzHttpWeb.DeviceLive.FormComponent do
  @moduledoc """
  Handles device form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.{ConnectivityChecks, Devices, Settings}

  def update(assigns, socket) do
    device = assigns.device
    changeset = Devices.change_device(device)
    default_device_endpoint = Settings.default_device_endpoint() || ConnectivityChecks.endpoint()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(Devices.defaults(changeset))
     |> assign(:default_device_allowed_ips, Settings.default_device_allowed_ips())
     |> assign(:default_device_dns_servers, Settings.default_device_dns_servers())
     |> assign(:default_device_endpoint, default_device_endpoint)
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
