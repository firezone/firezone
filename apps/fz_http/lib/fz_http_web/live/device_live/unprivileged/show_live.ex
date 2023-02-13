defmodule FzHttpWeb.DeviceLive.Unprivileged.Show do
  @moduledoc """
  Shows a device for an unprivileged user.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Devices
  alias FzHttp.Users

  @impl Phoenix.LiveView
  def mount(%{"id" => device_id} = _params, _session, socket) do
    device = Devices.get_device!(device_id)

    if authorized?(device, socket) do
      {:ok,
       socket
       |> assign(assigns(device))}
    else
      {:ok, not_authorized(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("delete_device", _params, socket) do
    device = socket.assigns.device

    case delete_device(device, socket) do
      {:ok, _deleted_device} ->
        {:noreply,
         socket
         |> redirect(to: ~p"/user_devices")}

      {:not_authorized} ->
        {:noreply, not_authorized(socket)}

      {:error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error deleting device: #{msg}")}
    end
  end

  def delete_device(device, socket) do
    if socket.assigns.current_user.id == device.user_id &&
         (has_role?(socket.assigns.current_user, :admin) ||
            FzHttp.Config.fetch_config!(:allow_unprivileged_device_management)) do
      Devices.delete_device(device)
    else
      {:not_authorized}
    end
  end

  defp assigns(device) do
    [
      device: device,
      user: Users.fetch_user_by_id!(device.user_id),
      page_title: device.name,
      allowed_ips: Devices.allowed_ips(device),
      port: FzHttp.Config.fetch_env!(:fz_vpn, :wireguard_port),
      dns: Devices.dns(device),
      endpoint: Devices.endpoint(device),
      mtu: Devices.mtu(device),
      persistent_keepalive: Devices.persistent_keepalive(device),
      config: Devices.as_config(device)
    ]
  end

  defp authorized?(device, socket) do
    "#{device.user_id}" == "#{socket.assigns.current_user.id}" || has_role?(socket, :admin)
  end
end
