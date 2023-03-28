defmodule FzHttpWeb.DeviceLive.Admin.Show do
  @moduledoc """
  Shows a device for an admin user.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{Devices, Users}

  @impl Phoenix.LiveView
  def mount(%{"id" => device_id} = _params, _session, socket) do
    with {:ok, device} <- Devices.fetch_device_by_id(device_id, socket.assigns.subject) do
      {:ok, assign(socket, assigns(device))}
    else
      {:error, {:unauthorized, _context}} ->
        {:ok, not_authorized(socket)}

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
    case Devices.delete_device(socket.assigns.device, socket.assigns.subject) do
      {:ok, _deleted_device} ->
        {:noreply, redirect(socket, to: ~p"/devices")}

      {:error, {:unauthorized, _context}} ->
        {:noreply, not_authorized(socket)}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Error deleting device: #{msg}")}
    end
  end

  defp assigns(device) do
    defaults = Devices.defaults()

    [
      device: device,
      user: Users.fetch_user_by_id!(device.user_id),
      page_title: device.name,
      allowed_ips: Devices.get_allowed_ips(device, defaults),
      dns: Devices.get_dns(device, defaults),
      endpoint: Devices.get_endpoint(device, defaults),
      port: FzHttp.Config.fetch_env!(:fz_vpn, :wireguard_port),
      mtu: Devices.get_mtu(device, defaults),
      persistent_keepalive: Devices.get_persistent_keepalive(device, defaults),
      config: FzHttpWeb.WireguardConfigView.render("device.conf", %{device: device})
    ]
  end
end
