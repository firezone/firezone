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
    with :ok <- authorize_socket_action(socket),
         {:ok, devices} <-
           Devices.list_devices_for_user(socket.assigns.current_user, socket.assigns.subject) do
      socket =
        socket
        |> assign(:devices, devices)
        |> assign(:page_subtitle, @page_subtitle)
        |> assign(:page_title, @page_title)

      {:ok, socket}
    else
      {:error, {:unauthorized, _context}} ->
        {:ok, not_authorized(socket)}
    end
  end

  defp authorize_socket_action(%{assigns: %{live_action: :new}} = socket) do
    Devices.authorize_user_device_management(socket.assigns.current_user, socket.assigns.subject)
  end

  defp authorize_socket_action(_socket) do
    :ok
  end

  @doc """
  This is called when modal is closed. Conveniently, allows us to reload devices table.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:ok, devices} =
      Devices.list_devices_for_user(socket.assigns.current_user, socket.assigns.subject)

    socket =
      socket
      |> assign(:devices, devices)

    {:noreply, socket}
  end
end
