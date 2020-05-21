defmodule FgHttpWeb.PasswordResetController do
  @moduledoc """
  Implements the CRUD for password resets
  """

  use FgHttpWeb, :controller
  alias FgHttp.{Users, Users.User}

  plug FgHttpWeb.Plugs.RedirectAuthenticated

  def new(conn, _params) do
    conn
    |> render("new.html", changeset: User.changeset(%User{}))
  end

  # Don't actually create anything. Instead, update the user with a reset token and send
  # the password reset email.
  def create(conn, %{
        "password_reset" =>
          %{
            reset_token: reset_token,
            password: _password,
            password_confirmation: _password_confirmation,
            current_password: _current_password
          } = user_params
      }) do
    user = Users.get_user!(reset_token: reset_token)

    case Users.update_user(user, user_params) do
      {:ok, _user} ->
        conn
        |> render("success.html")

      {:error, changeset} ->
        conn
        |> render("new.html", changeset: changeset)
    end
  end
end
