defmodule FzHttpWeb.DeviceLive.Unprivileged.FormComponent do
  @moduledoc """
  Handles device form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.{ConnectivityChecks, Devices, Sites}

  def update(assigns, socket) do
    device = assigns.device
    changeset = Devices.change_device(device)

    allowed_ips =
      Sites.get_site!().allowed_ips || Application.fetch_env!(:fz_http, :wireguard_allowed_ips)

    dns = Sites.get_site!().dns || Application.fetch_env!(:fz_http, :wireguard_dns)

    endpoint =
      Sites.get_site!().endpoint || Application.fetch_env!(:fz_http, :wireguard_endpoint) ||
        ConnectivityChecks.endpoint()

    persistent_keepalive =
      Sites.get_site!().persistent_keepalive ||
        Application.fetch_env!(:fz_http, :wireguard_persistent_keepalive)

    mtu = Sites.get_site!().mtu || Application.fetch_env!(:fz_http, :wireguard_mtu)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(Devices.defaults(changeset))
     |> assign(:allowed_ips, allowed_ips)
     |> assign(:dns, dns)
     |> assign(:endpoint, endpoint)
     |> assign(:mtu, mtu)
     |> assign(:persistent_keepalive, persistent_keepalive)
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
