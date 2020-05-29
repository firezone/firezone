defmodule FgHttpWeb.PasswordResetController do
  @moduledoc """
  Implements the CRUD for password resets
  """

  use FgHttpWeb, :controller
  alias FgHttp.{PasswordResets, Users.PasswordReset, Users.User}

  plug FgHttpWeb.Plugs.RedirectAuthenticated

  def new(conn, _params) do
    changeset = PasswordReset.changeset(%PasswordReset{}, %{})

    conn
    |> render("new.html", changeset: changeset)
  end

  def edit(conn, %{"token" => token}) when is_binary(token) do
    _user = load_user(conn, token)
    changeset = PasswordReset.changeset(%PasswordReset{}, %{})

    conn
    |> render("edit.html", changeset: changeset)
  end

  def update(conn, %{
        "password_reset" =>
          %{
            "reset_token" => token,
            "user" => %{
              "password" => _password,
              "password_confirmation" => _password_confirmation
            }
          } = password_reset_params
      })
      when is_binary(token) do
    user = load_user(conn, token)

    case PasswordResets.update_password_reset(user, password_reset_params) do
      {:ok, _user} ->
        conn
        |> clear_session()
        |> put_flash(:info, "User password updated successfully. Please sign in.")
        |> redirect(to: Routes.session_path(conn, :new))

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Error updating User password.")
        |> render("edit.html", changeset: changeset)
    end
  end

  def create(conn, %{"password_reset" => %{"user_email" => _} = password_reset_params}) do
    case PasswordResets.create_password_reset(password_reset_params) do
      {:ok, _password_reset} ->
        conn
        |> clear_session()
        |> put_flash(:info, "Password reset successfully. Please sign in with your new password.")
        |> redirect(to: Routes.session_path(conn, :new))

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Error creating password reset.")
        |> render("new.html", changeset: changeset)
    end
  end

  defp load_user(conn, token) do
    case PasswordResets.load_user_from_valid_token!(token) do
      nil ->
        conn
        |> put_status(:not_found)
        |> halt()

      %User{} = user ->
        user
    end
  end
end
