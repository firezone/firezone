defmodule CfHttpWeb.SessionController do
  @moduledoc """
  Implements the CRUD for a Session
  """

  use CfHttpWeb, :controller
  alias CfHttp.{Repo, Users.User, Sessions, Sessions.Session}

  plug :redirect_authenticated when action in [:new]
  plug CfHttpWeb.Plugs.Authenticator when action in [:delete]

  # GET /sessions/new
  def new(conn, _params) do
    changeset = Session.changeset(%Session{})

    render(conn, "new.html", changeset: changeset)
  end

  # Sign In
  # POST /sessions
  def create(conn, params) do
    changeset = Session.changeset(%Session{}, params)

    case Repo.insert(changeset) do
      {:ok, session} ->
        conn
        |> assign(:current_session, session)
        |> put_flash(:info, "Session created successfully")
        |> redirect(to: Routes.device_path(conn, :index))

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Error creating session.")
        |> render("new.html", changeset: changeset)
    end
  end

  # Sign Out
  # DELETE /session
  def delete(conn, _params) do
    case Repo.delete(conn.current_session) do
      {:ok, _session} ->
        conn
        |> assign(:current_session, nil)
        |> put_flash(:info, "Session deleted successfully.")
        |> redirect(to: "/")
    end
  end

  defp redirect_authenticated(conn, _) do
    user = %User{id: 1, email: "dev_user@fireguard.network"}
    session = %Session{user_id: user.id}

    conn
    |> assign(:current_session, session)
    |> redirect(to: "/")
    |> halt()
  end
end
