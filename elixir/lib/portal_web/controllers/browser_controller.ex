defmodule PortalWeb.BrowserController do
  use Web, :controller

  def config(conn, _params) do
    render(conn, "config.xml", layout: false)
  end
end
