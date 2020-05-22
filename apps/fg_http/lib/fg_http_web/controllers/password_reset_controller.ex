defmodule FgHttpWeb.PasswordResetController do
  @moduledoc """
  Implements the CRUD for password resets
  """

  use FgHttpWeb, :controller
  alias FgHttp.{PasswordResets, PasswordResets.PasswordReset}

  plug FgHttpWeb.Plugs.RedirectAuthenticated

  def new(conn, _params) do
    changeset = PasswordReset.changeset(%PasswordReset{}, %{})

    conn
    |> render("new.html", changeset: changeset)
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
end
