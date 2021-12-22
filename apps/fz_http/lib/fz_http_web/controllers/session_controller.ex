defmodule FzHttpWeb.SessionController do
  @moduledoc """
  Implements the CRUD for a Session
  """

  alias FzHttp.{Sessions, Users}
  use FzHttpWeb, :controller

  plug :put_root_layout, "auth.html"

  # GET /session/new
  def new(conn, _params) do
    if redirect_authenticated?(conn) do
      conn
      |> redirect(to: root_path_for_role(conn))
      |> halt()
    else
      changeset = Sessions.new_session()
      render(conn, "new.html", changeset: changeset)
    end
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
            |> assign(:current_session, session)
            |> activate_vpn()
            |> put_session(:user_id, session.id)
            |> put_session(:live_socket_id, "users_socket:#{session.id}")
            |> redirect(to: Routes.root_path(conn, :index))

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
        |> put_session(:live_socket_id, "users_socket:#{user.id}")
        |> redirect(to: Routes.device_index_path(conn, :index))

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

  defp redirect_authenticated?(conn) do
    user_id = get_session(conn, :user_id)
    Users.exists?(user_id)
  end

  defp activate_vpn(conn) do
    conn
    |> put_flash(:info, "VPN session activated!")
  end
end
