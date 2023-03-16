defmodule FzHttpWeb.DeviceLive.Admin.Show do
  @moduledoc """
  Shows a device for an admin user.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{Devices, Users}

  @impl Phoenix.LiveView
  def mount(%{"id" => device_id} = _params, _session, socket) do
    # TODO: subject
    with {:ok, device} <- Devices.fetch_device_by_id(device_id) do
      {:ok, assign(socket, assigns(device))}
    else
      {:error, :not_found} ->
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
         |> redirect(to: ~p"/devices")}

      {:error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error deleting device: #{msg}")}
    end
  end

  defp assigns(device) do
    defaults = Devices.defaults()

    [
      device: device,
      user: Users.fetch_user_by_id!(device.user_id),
      page_title: device.name,
      allowed_ips: Devices.allowed_ips(device, defaults),
      dns: Devices.dns(device, defaults),
      endpoint: Devices.endpoint(device, defaults),
      port: FzHttp.Config.fetch_env!(:fz_vpn, :wireguard_port),
      mtu: Devices.mtu(device, defaults),
      persistent_keepalive: Devices.persistent_keepalive(device, defaults),
      config: Devices.as_config(device)
    ]
  end
end
