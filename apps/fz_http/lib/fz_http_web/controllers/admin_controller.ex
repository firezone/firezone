defmodule FzHttpWeb.AdminController do
  @moduledoc """
  Testing the admin layout
  """
  use FzHttpWeb, :controller

  plug :put_root_layout, "admin.html"

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
