defmodule PortalWeb.Activity.Map do
  use PortalWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Live map")}
  end

  def render(assigns) do
    ~H"""
    <Page.page_header>
      <:title>Live map</:title>
      <:description>Connections as they are authorized, placed on the map.</:description>
    </Page.page_header>
    """
  end
end
