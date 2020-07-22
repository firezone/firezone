defmodule FgHttpWeb.UserController do
  @moduledoc """
  Implements the CRUD for a User
  """

  use FgHttpWeb, :controller
  alias FgHttp.{Sessions, Users, Users.User}

  plug FgHttpWeb.Plugs.SessionLoader when action in [:show, :edit, :update, :delete]
  plug :scrub_params, "user" when action in [:update]

  # GET /users/new
  def new(conn, _params) do
    changeset = Users.change_user(%User{})
    render(conn, "new.html", changeset: changeset)
  end

  # POST /users
  def create(conn, %{"user" => user_params}) do
    case Users.create_user(user_params) do
      {:ok, user} ->
        # XXX: Cast the user to a session struct to prevent this db call
        session = Sessions.get_session!(user.id)

        conn
        |> put_session(:user_id, user.id)
        |> assign(:session, session)
        |> put_flash(:info, "Account created successfully.")
        |> redirect(to: Routes.device_path(conn, :index))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "Error creating account.")
        |> render("new.html", changeset: changeset)
    end
  end

  # GET /user/edit
  def edit(conn, _params) do
    # XXX: Cast the session to a user struct to prevent this db call
    user = Users.get_user!(conn.assigns.session.id)
    changeset = Users.change_user(user)

    render(conn, "edit.html", changeset: changeset)
  end

  # GET /user
  def show(conn, _params) do
    # XXX: Cast the session to a user struct to prevent this db call
    user = Users.get_user!(conn.assigns.session.id)

    conn
    |> render("show.html", user: user, session: conn.assigns.session)
  end

  # PATCH /user
  def update(conn, %{"user" => user_params}) do
    user = Users.get_user!(conn.assigns.session.id)

    case Users.update_user(user, user_params) do
      {:ok, user} ->
        # XXX: Cast the user to a session struct to prevent this db call
        session = Sessions.get_session!(user.id)

        conn
        |> assign(:session, session)
        |> put_flash(:info, "Account updated successfully.")
        |> redirect(to: Routes.user_path(conn, :show))

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Error updating account.")
        |> render("edit.html", changeset: changeset)
    end
  end

  # DELETE /user
  def delete(conn, _params) do
    user = Users.get_user!(conn.assigns.session.id)

    case Users.delete_user(user) do
      {:ok, _user} ->
        conn
        |> clear_session()
        |> assign(:session, nil)
        |> put_flash(:info, "Account deleted successfully.")
        |> redirect(to: "/")

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Error deleting account.")
        |> render("edit.html", changeset: changeset)
    end
  end
end
