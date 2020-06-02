defmodule FgHttpWeb.PasswordResetController do
  @moduledoc """
  Implements the CRUD for password resets
  """

  use FgHttpWeb, :controller
  alias FgHttp.{Email, Mailer, PasswordResets, Users.PasswordReset}

  plug FgHttpWeb.Plugs.RedirectAuthenticated

  def edit(conn, %{"reset_token" => reset_token} = params) do
    password_reset = PasswordResets.get_password_reset!(reset_token: reset_token)

    conn
    |> render(
      "edit.html",
      changeset: PasswordReset.changeset(password_reset, params),
      password_reset: password_reset
    )
  end

  def new(conn, _params) do
    conn
    |> render("new.html", changeset: PasswordReset.changeset())
  end

  def update(conn, %{"password_reset" => %{"reset_token" => reset_token} = update_params}) do
    case PasswordResets.get_password_reset!(reset_token: reset_token) do
      %PasswordReset{} = password_reset ->
        case PasswordResets.update_password_reset(password_reset, update_params) do
          {:ok, _password_reset} ->
            conn
            |> put_flash(:info, "Password reset successfully. You may now sign in.")
            |> redirect(to: Routes.session_path(conn, :new))

          {:error, changeset} ->
            conn
            |> put_flash(:error, "Error updating password.")
            |> render("edit.html", changeset: changeset, password_reset: password_reset)
        end

      nil ->
        conn
        |> put_flash(:error, "Reset token invalid. Try resetting your password again.")
        |> render("new.html", changeset: PasswordReset.changeset())
    end
  end

  def create(conn, %{"password_reset" => %{"email" => email}}) do
    case PasswordResets.get_password_reset!(email: email) do
      %PasswordReset{} = record ->
        case PasswordResets.create_password_reset(record, %{email: email}) do
          {:ok, password_reset} ->
            send_email(password_reset)

            conn
            |> put_flash(:info, "Check your email for the password reset link.")
            |> redirect(to: Routes.session_path(conn, :new))

          {:error, changeset} ->
            conn
            |> put_flash(:error, "Error creating password reset.")
            |> render("new.html", changeset: changeset)
        end

      nil ->
        conn
        |> put_flash(:error, "Email not found.")
        |> render("new.html", changeset: PasswordReset.changeset())
    end
  end

  defp send_email(password_reset) do
    Email.password_reset(password_reset)
    |> Mailer.deliver_later()
  end
end
