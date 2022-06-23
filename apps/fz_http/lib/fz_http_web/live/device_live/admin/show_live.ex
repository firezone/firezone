defmodule FzHttpWeb.DeviceLive.Admin.Show do
  @moduledoc """
  Shows a device for an admin user.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{Devices, Users}

  @impl Phoenix.LiveView
  def mount(%{"id" => device_id} = _params, _session, socket) do
    device = Devices.get_device!(device_id)

    if device.user_id == socket.assigns.current_user.id || has_role?(socket, :admin) do
      {:ok,
       socket
       |> assign(assigns(device))}
    else
      {:ok, not_authorized(socket)}
    end
  end

  @doc """
  Needed because this view will receive handle_params when modal is closed.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_device", _params, socket) do
    device = socket.assigns.device

    case Devices.delete_device(device) do
      {:ok, _deleted_device} ->
        {:noreply,
         socket
         |> dispatch_delete_device(device)
         |> redirect(to: Routes.device_admin_index_path(socket, :index))}

      {:error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error deleting device: #{msg}")}
    end
  end

  @event_error_msg """
  Device deleted successfully but an error occured applying its configuration to the WireGuard
  interface. Check logs for more information.
  """
  defp dispatch_delete_device(socket, device) do
    case @events_module.delete_device(device) do
      :ok ->
        socket

      _err ->
        socket
        |> put_flash(:error, @event_error_msg)
    end
  end

  defp assigns(device) do
    [
      device: device,
      user: Users.get_user!(device.user_id),
      page_title: device.name,
      allowed_ips: Devices.allowed_ips(device),
      dns: Devices.dns(device),
      endpoint: Devices.endpoint(device),
      port: Application.fetch_env!(:fz_vpn, :wireguard_port),
      mtu: Devices.mtu(device),
      persistent_keepalive: Devices.persistent_keepalive(device),
      config: Devices.as_config(device)
    ]
  end
end
