defmodule FzHttpWeb.DeviceLive.Admin.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{Devices, Repo}

  @page_title "All Devices"
  @page_subtitle """
  Each device corresponds to a WireGuard configuration for connecting to this Firezone server.
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    devices =
      Devices.list_devices()
      |> Repo.preload(:user)
      |> Enum.sort_by(& &1.user_id)

    {:ok,
     socket
     |> assign(:devices, devices)
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
  end

  @doc """
  Needed because this view will receive handle_params when modal is closed.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
