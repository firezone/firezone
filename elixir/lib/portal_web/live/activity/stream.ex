defmodule PortalWeb.Activity.Stream do
  use PortalWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Activity")}
  end

  def render(assigns) do
    ~H"""
    <Page.page_header>
      <:title>Activity</:title>
      <:description>Every change, session, flow and API request in one stream.</:description>
    </Page.page_header>
    """
  end
end
