defmodule PortalWeb.BrowserController do
  use PortalWeb, :controller

  def config(conn, _params) do
    render(conn, "config.xml", layout: false)
  end
end
