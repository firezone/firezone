defmodule FzHttpWeb.SessionController do
  @moduledoc """
  Implements the CRUD for a Session
  """

  alias FzHttp.{Sessions, Users}
  use FzHttpWeb, :controller

  plug :put_root_layout, "auth.html"

  # GET /session/new
  def new(conn, _params) do
    changeset = Sessions.new_session()
    render(conn, "new.html", changeset: changeset)
  end

  # POST /session
  def create(conn, %{"session" => %{"email" => email, "password" => password}}) do
    case Sessions.get_session(email: email) do
      nil ->
        conn
        |> put_flash(:error, "Email not found.")
        |> assign(:changeset, Sessions.new_session())
        |> redirect(to: Routes.session_path(conn, :new))

      record ->
        case Sessions.create_session(record, %{email: email, password: password}) do
          {:ok, session} ->
            conn
            |> clear_session()
            |> put_session(:user_id, session.id)
            |> redirect(to: Routes.device_path(conn, :index))

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Error signing in. Ensure email and password are correct.")
            |> assign(:changeset, Sessions.new_session())
            |> redirect(to: Routes.session_path(conn, :new))
        end
    end
  end

  # GET /sign_in/:token
  def create(conn, %{"token" => token}) do
    case Users.consume_sign_in_token(token) do
      {:ok, user} ->
        conn
        |> clear_session()
        |> put_session(:user_id, user.id)
        |> redirect(to: Routes.device_path(conn, :index))

      {:error, error_msg} ->
        conn
        |> put_flash(:error, error_msg)
        |> redirect(to: Routes.session_path(conn, :new))
    end
  end

  # DELETE /sign_out
  def delete(conn, _params) do
    # XXX: Disconnect all WebSockets.
    conn
    |> clear_session()
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: Routes.session_path(conn, :new))
  end
end
