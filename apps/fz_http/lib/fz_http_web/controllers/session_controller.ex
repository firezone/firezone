defmodule FzHttpWeb.SessionController do
  @moduledoc """
  Implements the CRUD for a Session
  """

  alias FzHttp.Users
  alias FzHttpWeb.Authentication

  use FzHttpWeb, :controller

  # GET /sign_in
  def new(conn, _params) do
    if user = Authentication.get_current_user(conn) do
      conn
      |> redirect(to: root_path_for_role(conn, user.role))
    else
      conn
      |> render(
        "new.html",
        changeset: Users.change_user(),
        action: Routes.session_path(conn, :create)
      )
    end
  end

  # POST /sign_in
  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Users.get_by_email(email) |> Authentication.authenticate(password) do
      {:ok, user} ->
        conn
        |> Authentication.sign_in(user)
        |> put_session(:live_socket_id, "users_socket:#{user.id}")
        |> redirect(to: root_path_for_role(conn, user.role))

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Incorrect email or password.")
        |> new(%{})
    end
  end

  # DELETE /sign_out
  def delete(conn, _params) do
    conn
    |> Authentication.sign_out()
    |> redirect(to: Routes.session_path(conn, :new))
  end
end
