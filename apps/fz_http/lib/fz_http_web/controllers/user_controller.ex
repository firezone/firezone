defmodule FzHttpWeb.UserController do
  @moduledoc """
  Implements synchronous User requests.
  """

  alias FzHttp.Users
  use FzHttpWeb, :controller

  plug :redirect_unauthenticated

  def delete(conn, _params) do
    user_id = get_session(conn, :user_id)
    user = Users.get_user!(user_id)

    case Users.delete_user(user) do
      {:ok, _user} ->
        # XXX: Disconnect all WebSockets.
        conn
        |> clear_session()
        |> put_flash(:info, "Account deleted successfully.")
        |> redirect(to: Routes.root_index_path(conn, :index))

        # delete_user is unlikely to fail, if so write a test for it and uncomment this
        # {:error, msg} ->
        #   conn
        #   |> clear_session()
        #   |> put_flash(:error, "Error deleting account: #{msg}")
        #   |> redirect(to: Routes.root_index_path(conn, :index))
    end
  end

  def redirect_unauthenticated(conn, _options) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Forbidden")
        |> halt()

      _ ->
        conn
    end
  end
end
