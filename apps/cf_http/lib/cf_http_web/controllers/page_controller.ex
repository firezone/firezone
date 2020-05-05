defmodule CfPhxWeb.PageController do
  use CfPhxWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
