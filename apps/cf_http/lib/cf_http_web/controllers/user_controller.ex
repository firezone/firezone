defmodule CfHttpWeb.UserController do
  @moduledoc """
  Implements the CRUD for a User
  """

  use CfHttpWeb, :controller
  alias CfHttp.{Repo, Users.User}

  plug CfHttpWeb.Plugs.Authenticator when action in [:show, :edit, :update, :delete]

  # GET /users/new
  def new(conn, _params) do
    changeset = User.changeset(%User{})

    conn
    |> render("new.html", changeset: changeset)
  end

  # POST /users
  def create(conn, params) do
    changeset = User.changeset(%User{}, params)

    case Repo.insert(changeset) do
      {:ok, user} ->
        conn
        |> assign(:current_user, user)
        |> put_flash(:info, "User created successfully")
        |> redirect(to: Routes.device_path(conn, :index))

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Error creating user.")
        |> render("new.html", changeset: changeset)
    end
  end

  # GET /user/edit
  def edit(conn, _params) do
    changeset = User.changeset(conn.current_user)

    conn
    |> render("edit.html", changeset: changeset)
  end

  # GET /user
  def show(conn, _params) do
    conn
    |> render("show.html", user: conn.current_user)
  end

  # PATCH /user
  def update(conn, params) do
    changeset = User.changeset(conn.current_user, params)

    case Repo.update(changeset) do
      {:ok, user} ->
        conn
        |> assign(:current_user, user)
        |> put_flash(:info, "User updated successfully.")
        |> redirect(to: Routes.user_path(conn, :show, conn.current_user))

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Error updating user.")
        |> render("edit.html", changeset: changeset)
    end
  end

  # DELETE /user
  def delete(conn, _params) do
    case Repo.delete(conn.current_user) do
      {:ok, _user} ->
        conn
        |> assign(:current_user, nil)
        |> put_flash(:info, "User deleted successfully.")
        |> redirect(to: Routes.page_path(conn, :index))

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Error deleting User.")
        |> redirect(to: Routes.user_path(:show, conn.current_user))
    end
  end
end
