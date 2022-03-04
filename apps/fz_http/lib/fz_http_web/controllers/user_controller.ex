defmodule FzHttpWeb.UserController do
  @moduledoc """
  Implements synchronous User requests.
  """

  alias FzHttp.Users
  alias FzHttpWeb.Authentication
  use FzHttpWeb, :controller

  def delete(conn, _params) do
    user = Authentication.get_current_user(conn)

    case Users.delete_user(user) do
      {:ok, _user} ->
        FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})

        conn
        |> clear_session()
        |> put_flash(:info, "Account deleted successfully.")
        |> redirect(to: Routes.root_path(conn, :index))

      {:error, msg} ->
        conn
        |> clear_session()
        |> put_flash(:error, "Error deleting account: #{msg}")
        |> redirect(to: Routes.root_path(conn, :index))
    end
  end
end
