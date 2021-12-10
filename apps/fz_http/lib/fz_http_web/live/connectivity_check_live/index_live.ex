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
     |> assign(:page_title, "Connectivity Checks")}
  end

  defp load_data(_params, socket) do
    assign(socket, :connectivity_checks, ConnectivityChecks.list_connectivity_checks(limit: 20))
  end
end
