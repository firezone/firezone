defmodule FzHttpWeb.UserController do
  @moduledoc """
  Implements synchronous User requests.
  """

  alias FzHttp.Users
  alias FzHttpWeb.Authentication
  use FzHttpWeb, :controller

  def reset_password(conn, %{"email" => _email} = attrs) do
    with :ok <- Users.reset_sign_in_token(attrs) do
      conn
      |> put_flash(:info, "Please check your inbox for the password reset link.")
      |> redirect(to: Routes.root_path(conn, :index))
    else
      :error ->
        conn
        |> put_flash(:warning, "Failed to send password reset email.")
        |> redirect(to: Routes.auth_path(conn, :forgot_password))
    end
  end

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
