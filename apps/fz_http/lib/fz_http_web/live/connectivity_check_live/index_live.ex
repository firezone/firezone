defmodule FzHttpWeb.ConnectivityCheckLive.Index do
  @moduledoc """
  Manages the connectivity_checks view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.ConnectivityChecks

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    connectivity_checks = ConnectivityChecks.list_connectivity_checks(limit: 20)

    {:ok,
     socket
     |> assign(:connectivity_checks, connectivity_checks)
     |> assign(:page_title, "WAN Connectivity Checks")}
  end
end
