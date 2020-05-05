defmodule CfHttpWeb.PageController do
  use CfHttpWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
