defmodule PortalWeb.Access.ByGroup do
  use PortalWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Policies by group")}
  end

  def render(assigns) do
    ~H"""
    <Page.page_header>
      <:title>Policies by group</:title>
      <:description>What each group can reach.</:description>
    </Page.page_header>
    """
  end
end
