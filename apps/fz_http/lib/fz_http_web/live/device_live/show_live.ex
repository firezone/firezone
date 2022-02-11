defmodule FzHttpWeb.DeviceLive.Show do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Devices, Users}

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign(:dropdown_active_class, "")
     |> assign_defaults(params, session, &load_data/2)}
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

    if authorized?(socket.assigns.current_user, device) do
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

    if authorized?(socket.assigns.current_user, device) do
      socket
      |> assign(
        device: device,
        user: Users.get_user!(device.user_id),
        page_title: device.name,
        allowed_ips: Devices.allowed_ips(device),
        dns: Devices.dns(device),
        endpoint: Devices.endpoint(device),
        mtu: Devices.mtu(device),
        persistent_keepalive: Devices.persistent_keepalive(device),
        config: Devices.as_config(device)
      )
    else
      not_authorized(socket)
    end
  end

  defp authorized?(user, device) do
    device.user_id == user.id || user.role == :admin
  end
end
