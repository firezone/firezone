defmodule FzHttpWeb.ConnectivityCheckLive.Index do
  @moduledoc """
  Manages the connectivity_checks view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.ConnectivityChecks

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)
     |> assign(:page_title, "WAN Connectivity Checks")}
  end

  defp load_data(_params, socket) do
    user = socket.assigns.current_user

    if user.role == :admin do
      socket
      |> assign(:connectivity_checks, ConnectivityChecks.list_connectivity_checks(limit: 20))
    else
      not_authorized(socket)
    end
  end
end
