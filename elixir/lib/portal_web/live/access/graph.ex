defmodule PortalWeb.Access.Graph do
  use PortalWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Access")}
  end

  def render(assigns) do
    ~H"""
    <Page.page_header>
      <:title>Access</:title>
      <:description>Who can reach what, through which site, carried by which device.</:description>
    </Page.page_header>
    """
  end
end
