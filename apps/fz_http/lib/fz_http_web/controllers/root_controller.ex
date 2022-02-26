defmodule FzHttpWeb.RootController do
  @moduledoc """
  Handles redirecting from /
  """
  use FzHttpWeb, :controller
  alias FzHttpWeb.Authentication

  def index(conn, _params) do
    if user = Authentication.get_current_user(conn) do
      conn
      |> redirect(to: root_path_for_role(conn, user.role))
    else
      conn
      |> put_flash(:error, "You must be signed in.")
      |> redirect(to: Routes.session_path(conn, :new))
    end
  end
end
