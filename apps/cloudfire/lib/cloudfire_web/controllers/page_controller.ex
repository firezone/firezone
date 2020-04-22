defmodule CloudfireWeb.PageController do
  use CloudfireWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
