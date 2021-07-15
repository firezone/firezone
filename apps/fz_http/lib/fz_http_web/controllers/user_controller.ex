defmodule FzHttpWeb.UserController do
  @moduledoc """
  Implements synchronous User requests.
  """

  alias FzHttp.Users
  use FzHttpWeb, :controller

  plug :require_authenticated

  def delete(conn, _params) do
    user_id = get_session(conn, :user_id)
    user = Users.get_user!(user_id)

    case Users.delete_user(user) do
      {:ok, _user} ->
        # XXX: Disconnect all WebSockets.
        conn
        |> clear_session()
        |> put_flash(:info, "Account deleted successfully.")
        |> redirect(to: Routes.session_path(conn, :new))

      {:error, msg} ->
        conn
        |> clear_session()
        |> put_flash(:error, "Error deleting account: #{msg}")
        |> redirect(to: Routes.session_path(conn, :new))
    end
  end
end
