defmodule FzHttpWeb.BrowserController do
  use FzHttpWeb, :controller

  def config(conn, _params) do
    render(conn, "browserconfig.xml")
  end
end
