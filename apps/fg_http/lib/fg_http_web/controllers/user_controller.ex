defmodule FgHttpWeb.UserController do
  @moduledoc """
  Implements the CRUD for a User
  """

  use FgHttpWeb, :controller
  alias FgHttp.{Users, Users.User}

  plug FgHttpWeb.Plugs.SessionLoader when action in [:show, :edit, :update, :delete]

  # GET /users/new
  def new(conn, _params) do
    changeset = Users.change_user(%User{})
    render(conn, "new.html", changeset: changeset)
  end

  # POST /users
  def create(conn, %{"user" => user_params}) do
    case Users.create_user(user_params) do
      {:ok, user} ->
        conn
        |> assign(:current_user, user)
        |> put_flash(:info, "User created successfully.")
        |> redirect(to: Routes.device_path(conn, :index))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "Error creating user.")
        |> render("new.html", changeset: changeset)
    end
  end

  # GET /user/edit
  def edit(conn, _params) do
    user = conn.current_user
    changeset = Users.change_user(user)

    render(conn, "edit.html", changeset: changeset)
  end

  # GET /user
  def show(conn, _params) do
    conn
    |> render("show.html", user: conn.current_user)
  end

  # PATCH /user
  def update(conn, params) do
    case Users.update_user(conn.current_user, params) do
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
    case Users.delete_user(conn.current_user) do
      {:ok, _user} ->
        conn
        |> assign(:current_user, nil)
        |> put_flash(:info, "User deleted successfully.")
        |> redirect(to: "/")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Error deleting User.")
        |> redirect(to: Routes.user_path(:show, conn.current_user))
    end
  end
end
