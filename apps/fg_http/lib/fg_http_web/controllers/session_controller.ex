defmodule FgHttpWeb.SessionController do
  @moduledoc """
  Implements the CRUD for a Session
  """

  alias FgHttp.{Sessions, Users.Session}
  use FgHttpWeb, :controller

  plug FgHttpWeb.Plugs.RedirectAuthenticated when action in [:new]
  plug FgHttpWeb.Plugs.SessionLoader when action in [:delete]

  # GET /sessions/new
  def new(conn, _params) do
    render(conn, "new.html")
  end

  # POST /sessions
  def create(conn, %{"session" => %{"email" => email} = session_params}) do
    case Sessions.get_session!(email: email) do
      %Session{} = session ->
        case Sessions.create_session(session, session_params) do
          {:ok, session} ->
            conn
            |> clear_session()
            |> put_session(:user_id, session.id)
            |> assign(:session, session)
            |> put_flash(:info, "Session created successfully")
            |> redirect(to: Routes.device_path(conn, :index))

          {:error, changeset} ->
            conn
            |> clear_session()
            |> assign(:session, nil)
            |> put_flash(:error, "Error creating session.")
            |> render("new.html", changeset: changeset)
        end

      nil ->
        conn
        |> put_flash(:error, "Email not found.")
        |> render("new.html")
    end
  end

  # DELETE /session
  def delete(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: "/")
  end
end
