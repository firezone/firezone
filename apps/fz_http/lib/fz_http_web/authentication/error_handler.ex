defmodule FzHttpWeb.Authentication.ErrorHandler do
  @moduledoc """
  Error Handler module implementation for Guardian.
  """

  use FzHttpWeb, :controller
  alias FzHttpWeb.Authentication
  alias FzHttpWeb.Router.Helpers, as: Routes
  import FzHttpWeb.ControllerHelpers, only: [root_path_for_role: 2]

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {:already_authenticated, _reason}, _opts) do
    user = Authentication.get_current_user(conn)

    conn
    |> redirect(to: root_path_for_role(conn, user.role))
  end

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {:unauthenticated, _reason}, _opts) do
    conn
    |> redirect(to: Routes.session_path(conn, :new))
  end

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, _reason}, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, to_string(type))
  end
end
