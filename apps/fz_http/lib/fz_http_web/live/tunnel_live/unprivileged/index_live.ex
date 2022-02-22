defmodule FzHttpWeb.TunnelLive.Unprivileged.Index do
  @moduledoc """
  Handles Tunnel LiveViews.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.Tunnels

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id

    {:ok,
     socket
     |> assign(:tunnels, Tunnels.list_tunnels(user_id))
     |> assign(:page_title, "WireGuard Tunnels")}
  end

  @doc """
  This is called when modal is closed. Conveniently, allows us to reload
  tunnels table.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    user_id = socket.assigns.current_user.id

    {:noreply,
     socket
     |> assign(:tunnels, Tunnels.list_tunnels(user_id))}
  end
end
