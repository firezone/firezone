defmodule FzHttpWeb.DeviceLive.Unprivileged.Show do
  @moduledoc """
  Shows a device for an unprivileged user.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Devices
  alias FzHttp.Users

  @impl Phoenix.LiveView
  def mount(%{"id" => device_id} = _params, _session, socket) do
    with {:ok, device} <- Devices.fetch_device_by_id(device_id, socket.assigns.subject) do
      {:ok, assign(socket, assigns(device))}
    else
      {:error, {:unauthorized, _}} ->
        {:ok, not_authorized(socket)}

      {:error, :not_found} ->
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
    # TODO: remove this
    if socket.assigns.current_user.id == device.user_id &&
         (has_role?(socket.assigns.current_user, :admin) ||
            FzHttp.Config.fetch_config!(:allow_unprivileged_device_management)) do
      Devices.delete_device(device, socket.assigns.subject)
    else
      {:not_authorized}
    end
  end

  defp assigns(device) do
    defaults = Devices.defaults()

    [
      device: device,
      user: Users.fetch_user_by_id!(device.user_id),
      page_title: device.name,
      allowed_ips: Devices.get_allowed_ips(device, defaults),
      port: FzHttp.Config.fetch_env!(:fz_vpn, :wireguard_port),
      dns: Devices.get_dns(device, defaults),
      endpoint: Devices.get_endpoint(device, defaults),
      mtu: Devices.get_mtu(device, defaults),
      persistent_keepalive: Devices.get_persistent_keepalive(device, defaults),
      config: FzHttpWeb.WireguardConfigView.render("device.conf", %{device: device})
    ]
  end
end
