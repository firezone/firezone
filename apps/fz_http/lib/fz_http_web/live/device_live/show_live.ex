defmodule FzHttpWeb.DeviceLive.Show do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Devices, Users}

  @impl true
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_device", %{"device_id" => device_id}, socket) do
    device = Devices.get_device!(device_id)

    if device.user_id == socket.assigns.current_user.id do
      case Devices.delete_device(device) do
        {:ok, _deleted_device} ->
          {:ok, _deleted_pubkey} = @events_module.delete_device(device.public_key)

          {:noreply,
           socket
           |> redirect(to: Routes.device_index_path(socket, :index))}

          # Not likely to ever happen
          # {:error, msg} ->
          #   {:noreply,
          #   socket
          #   |> put_flash(:error, "Error deleting device: #{msg}")}
      end
    else
      {:noreply, not_authorized(socket)}
    end
  end

  defp load_data(%{"id" => id}, socket) do
    device = Devices.get_device!(id)

    if device.user_id == socket.assigns.current_user.id do
      assign(
        socket,
        device: device,
        user: Users.get_user!(device.user_id),
        page_title: device.name,
        allowed_ips: Devices.allowed_ips(device),
        dns_servers: dns_servers(device),
        endpoint: Devices.endpoint(device),
        wireguard_port: Application.fetch_env!(:fz_vpn, :wireguard_port)
      )
    else
      not_authorized(socket)
    end
  end

  defp dns_servers(device) when is_struct(device) do
    dns_servers = Devices.dns_servers(device)

    if dns_servers_empty?(dns_servers) do
      ""
    else
      "DNS = #{dns_servers}"
    end
  end

  defp dns_servers_empty?(nil), do: true

  defp dns_servers_empty?(dns_servers) when is_binary(dns_servers) do
    len =
      dns_servers
      |> String.trim()
      |> String.length()

    len == 0
  end
end
