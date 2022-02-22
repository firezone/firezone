defmodule FzHttpWeb.TunnelLive.Admin.Index do
  @moduledoc """
  Handles Tunnel LiveViews.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.Tunnels

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:tunnels, Tunnels.list_tunnels())
     |> assign(:page_title, "All Tunnels")}
  end

  @doc """
  Needed because this view will receive handle_params when modal is closed.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
