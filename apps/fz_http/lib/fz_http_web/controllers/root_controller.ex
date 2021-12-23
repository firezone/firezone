defmodule FzHttpWeb.RootController do
  @moduledoc """
  Handles redirecting from /
  """
  use FzHttpWeb, :controller

  plug :redirect_unauthenticated

  def index(conn, _params) do
    conn
    |> redirect(to: root_path_for_role(conn))
  end
end
