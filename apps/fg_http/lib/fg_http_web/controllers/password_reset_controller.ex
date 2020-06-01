defmodule FgHttpWeb.PasswordResetController do
  @moduledoc """
  Implements the CRUD for password resets
  """

  use FgHttpWeb, :controller
  alias FgHttp.{PasswordResets, Users.PasswordReset}

  plug FgHttpWeb.Plugs.RedirectAuthenticated

  def new(conn, _params) do
    conn
    |> render("new.html", changeset: PasswordReset.changeset())
  end

  def create(conn, %{"password_reset" => %{"email" => email}}) do
    case PasswordResets.get_password_reset!(email: email) do
      %PasswordReset{} = record ->
        case PasswordResets.create_password_reset(record, %{email: email}) do
          {:ok, _password_reset} ->
            conn
            |> clear_session()
            |> put_flash(:info, "Check your email for the password reset link.")
            |> redirect(to: Routes.session_path(conn, :new))

          {:error, changeset} ->
            conn
            |> put_flash(:error, "Error creating password reset.")
            |> render("new.html", changeset: changeset)
        end

      nil ->
        conn
        |> put_flash(:error, "User not found.")
        |> render("new.html", changeset: PasswordReset.changeset())
    end
  end
end
