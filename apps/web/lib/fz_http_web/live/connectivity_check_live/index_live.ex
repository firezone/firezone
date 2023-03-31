defmodule FzHttpWeb.ConnectivityCheckLive.Index do
  @moduledoc """
  Manages the connectivity_checks view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.ConnectivityChecks

  @page_title "WAN Connectivity Checks"
  @page_subtitle """
  Firezone periodically checks for WAN connectivity to the Internet and logs the result here. \
  This is used to determine the public IP address of this server for populating the default \
  endpoint field in device configurations.
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    connectivity_checks =
      ConnectivityChecks.list_connectivity_checks(socket.assigns.subject, limit: 20)

    socket =
      socket
      |> assign(:connectivity_checks, connectivity_checks)
      |> assign(:page_subtitle, @page_subtitle)
      |> assign(:page_title, @page_title)

    {:ok, socket}
  end
end
