defmodule FzHttpWeb.DeviceLive.Admin.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.Devices

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:devices, Devices.list_devices())
     |> assign(:page_title, "All Devices")}
  end

  @doc """
  Needed because this view will receive handle_params when modal is closed.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
