defmodule FzHttpWeb.DeviceLive.Unprivileged.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.Devices

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id

    {:ok,
     socket
     |> assign(:devices, Devices.list_devices(user_id))
     |> assign(:page_title, "Your Devices")}
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
