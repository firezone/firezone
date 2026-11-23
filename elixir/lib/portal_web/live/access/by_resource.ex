defmodule PortalWeb.Access.ByResource do
  use PortalWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Policies by resource")}
  end

  def render(assigns) do
    ~H"""
    <Page.page_header>
      <:title>Policies by resource</:title>
      <:description>Who can reach each resource.</:description>
    </Page.page_header>
    """
  end
end
