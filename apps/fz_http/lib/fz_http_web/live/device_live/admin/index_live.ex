defmodule FzHttpWeb.DeviceLive.Admin.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Devices

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)
     |> assign(:page_title, "Devices")}
  end

  @doc """
  Needed because this view will receive handle_params when modal is closed.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_data(_params, socket) do
    # XXX: Update this to use new LiveView session auth
    user = socket.assigns.current_user

    if user.role == :admin do
      assign(socket, :devices, Devices.list_devices())
    else
      not_authorized(socket)
    end
  end
end
