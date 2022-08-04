defmodule FzHttpWeb.DeviceLive.Unprivileged.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.Devices

  @page_title "Your Devices"
  @page_subtitle """
  Each device corresponds to a WireGuard configuration for connecting to this Firezone server.
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:devices, Devices.list_devices(user.id))
     |> assign(:user, user)
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
  end

  @doc """
  This is called when modal is closed. Conveniently, allows us to reload
  devices table.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    user_id = socket.assigns.current_user.id

    {:noreply,
     socket
     |> assign(:devices, Devices.list_devices(user_id))}
  end
end
