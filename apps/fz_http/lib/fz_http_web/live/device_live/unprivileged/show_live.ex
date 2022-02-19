defmodule FzHttpWeb.DeviceLive.Unprivileged.Show do
  @moduledoc """
  Shows a device for an unprivileged user.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{Devices, Users}

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
        {:ok, _deleted_pubkey} = @events_module.delete_device(device.public_key)

        {:noreply,
         socket
         |> redirect(to: Routes.device_unprivileged_index_path(socket, :index))}

      {:not_authorized} ->
        {:noreply, not_authorized(socket)}

        # Not likely to ever happen
        # {:error, msg} ->
        #   {:noreply,
        #   socket
        #   |> put_flash(:error, "Error deleting device: #{msg}")}
    end
  end

  def delete_device(device, socket) do
    if socket.assigns.current_user.id == device.user_id do
      Devices.delete_device(device)
    else
      {:not_authorized}
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
      mtu: Devices.mtu(device),
      persistent_keepalive: Devices.persistent_keepalive(device),
      config: Devices.as_config(device)
    ]
  end

  defp authorized?(device, socket) do
    "#{device.user_id}" == "#{socket.assigns.current_user.id}" || has_role?(socket, :admin)
  end
end
