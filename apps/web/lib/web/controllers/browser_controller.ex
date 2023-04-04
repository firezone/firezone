defmodule Web.BrowserController do
  use Web, :controller

  def config(conn, _params) do
    render(conn, "browserconfig.xml")
  end
end
