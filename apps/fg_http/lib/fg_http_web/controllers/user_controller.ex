defmodule FgHttpWeb.UserController do
  @moduledoc """
  Implements synchronous User requests.
  """

  alias FgHttp.Users
  use FgHttpWeb, :controller

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

      {:error, msg} ->
        conn
        |> put_flash(:error, "Error deleting account: #{msg}")
        |> redirect(to: Routes.root_index_path(conn, :index))
    end
  end
end
